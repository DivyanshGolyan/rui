const std = @import("std");
const host_store = @import("host_store.zig");
const model_protocol = @import("model_protocol.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/resource.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

const populations = [_]u64{ 100, 1_000, 10_000 };
const task = "Measure one durable agent lifecycle.";

pub fn main(init: std.process.Init) !void {
    try host_store.configureProcessHeapLimit(8 * 1024 * 1024);
    defer host_store.disableProcessHeapLimit();

    var random_identity: [8]u8 = undefined;
    init.io.random(&random_identity);
    var root_path_buffer: [128]u8 = undefined;
    const root_path = try std.fmt.bufPrint(
        &root_path_buffer,
        ".zig-cache/onepage-host-store-density-{x}",
        .{std.mem.readInt(u64, &random_identity, .little)},
    );
    var root = try std.Io.Dir.cwd().createDirPathOpen(init.io, root_path, .{});
    defer {
        root.close(init.io);
        std.Io.Dir.cwd().deleteTree(init.io, root_path) catch {
            // Measurement cleanup must not replace the measured result.
        };
    }

    for (populations) |population| try measure(init.io, root, root_path, population);
    try measureTransientCapture(init.io, root, root_path, .ordinary);
    try measureTransientCapture(init.io, root, root_path, .maximum_model_response);
    try measureMaximumSessionScratch(init.io, root, root_path);
}

const JournalSampler = struct {
    io: std.Io,
    path: []const u8,
    maximum_logical_bytes: u64 = 0,
    maximum_allocated_bytes: u64 = 0,

    fn hook(self: *JournalSampler) host_store.FaultHook {
        return .{ .context = self, .reached = reached };
    }

    fn reached(context: *anyopaque, boundary: host_store.FaultBoundary) !void {
        if (boundary != .before_commit) return;
        const self: *JournalSampler = @ptrCast(@alignCast(context));
        const logical = fileSize(self.io, self.path) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        const allocated = try fileAllocatedBytes(self.io, self.path);
        self.maximum_logical_bytes = @max(self.maximum_logical_bytes, logical);
        self.maximum_allocated_bytes = @max(self.maximum_allocated_bytes, allocated);
    }
};

const ProcessUsage = struct {
    disk_read_bytes: u64,
    disk_write_bytes: u64,
    physical_footprint_bytes: u64,
};

fn measure(
    io: std.Io,
    root: std.Io.Dir,
    root_path: []const u8,
    population: u64,
) !void {
    var path_buffer: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{d}.sqlite3",
        .{ root_path, population },
    );
    var journal_path_buffer: [264]u8 = undefined;
    const journal_path = try std.fmt.bufPrint(&journal_path_buffer, "{s}-journal", .{path});
    var journal: JournalSampler = .{ .io = io, .path = journal_path };
    var owner = try host_store.StorageOwner.open(io, path, .{ .fault = journal.hook() });
    defer owner.close();
    _ = try owner.memoryAccounting(true);
    _ = try owner.physicalAccounting(true);
    const usage_before = try processUsage();
    const started = std.Io.Clock.awake.now(io);
    var transaction_latencies: [populations[populations.len - 1]]u64 = undefined;
    var live_transient_scratch_owners: usize = 0;

    for (0..@as(usize, @intCast(population))) |index| {
        const transaction_started = std.Io.Clock.awake.now(io);
        {
            const scratch = try session_store.allocateTransientScratch(std.heap.page_allocator);
            live_transient_scratch_owners += 1;
            defer {
                session_store.destroyTransientScratch(std.heap.page_allocator, io, scratch);
                live_transient_scratch_owners -= 1;
            }
            var session = try session_store.Session.create(root, scratch, &owner, io, .{
                .workspace_path = ".",
                .model = "fixture:density",
                .task = task,
            });
            defer session.close();
        }
        transaction_latencies[index] = @intCast(
            transaction_started.untilNow(io, .awake).toNanoseconds(),
        );
    }
    if (live_transient_scratch_owners != 0) return error.TransientScratchMeasurementLeak;

    const elapsed = started.untilNow(io, .awake);
    const usage_after = try processUsage();
    const memory = try owner.memoryAccounting(false);
    const physical = try owner.physicalAccounting(false);
    const database_file_bytes = try fileSize(io, path);
    const database_allocated_bytes = try fileAllocatedBytes(io, path);
    const journal_file_bytes = fileSize(io, journal_path) catch |err| switch (err) {
        error.FileNotFound => 0,
        else => return err,
    };
    const disk_read_bytes = usage_after.disk_read_bytes - usage_before.disk_read_bytes;
    const disk_write_bytes = usage_after.disk_write_bytes - usage_before.disk_write_bytes;
    const elapsed_ns: u64 = @intCast(elapsed.toNanoseconds());
    const sessions_per_second = if (elapsed_ns == 0)
        0
    else
        population * std.time.ns_per_s / elapsed_ns;
    const latency_count: usize = @intCast(population);
    std.mem.sort(u64, transaction_latencies[0..latency_count], {}, std.sort.asc(u64));
    const latency_p50 = percentile(transaction_latencies[0..latency_count], 50);
    const latency_p95 = percentile(transaction_latencies[0..latency_count], 95);
    const latency_p99 = percentile(transaction_latencies[0..latency_count], 99);
    var line: [1600]u8 = undefined;
    const encoded = try std.fmt.bufPrint(
        &line,
        "{{\"sessions\":{d},\"logical_content_bytes\":{d},\"database_file_bytes\":{d},\"database_allocated_bytes\":{d},\"journal_file_bytes_after_commit\":{d},\"journal_highwater_logical_bytes\":{d},\"journal_highwater_allocated_bytes\":{d},\"sqlite_allocated_bytes\":{d},\"sqlite_free_bytes\":{d},\"sqlite_page_writes\":{d},\"sqlite_cache_spills\":{d},\"process_disk_read_bytes\":{d},\"process_disk_write_bytes\":{d},\"wall_ns\":{d},\"transaction_mean_ns\":{d},\"transaction_p50_ns\":{d},\"transaction_p95_ns\":{d},\"transaction_p99_ns\":{d},\"sessions_per_second\":{d},\"resident_bytes\":{d},\"physical_footprint_bytes\":{d},\"sqlite_heap_current_bytes\":{d},\"sqlite_heap_highwater_bytes\":{d},\"live_transient_scratch_owners_before_sampling\":{d}}}\n",
        .{
            population,
            population * task.len,
            database_file_bytes,
            database_allocated_bytes,
            journal_file_bytes,
            journal.maximum_logical_bytes,
            journal.maximum_allocated_bytes,
            physical.page_count * physical.page_size_bytes,
            physical.free_page_count * physical.page_size_bytes,
            physical.cache_page_writes,
            physical.cache_spills,
            disk_read_bytes,
            disk_write_bytes,
            elapsed_ns,
            elapsed_ns / population,
            latency_p50,
            latency_p95,
            latency_p99,
            sessions_per_second,
            try residentBytes(),
            usage_after.physical_footprint_bytes,
            memory.heap_current_bytes,
            memory.heap_highwater_bytes,
            live_transient_scratch_owners,
        },
    );
    try std.Io.File.stdout().writeStreamingAll(io, encoded);
}

const TransientSample = enum {
    ordinary,
    maximum_model_response,

    fn name(self: TransientSample) []const u8 {
        return switch (self) {
            .ordinary => "ordinary_response_transient",
            .maximum_model_response => "maximum_model_response_transient",
        };
    }
};

fn measureTransientCapture(
    io: std.Io,
    root: std.Io.Dir,
    root_path: []const u8,
    sample: TransientSample,
) !void {
    var sessions_name_buffer: [48]u8 = undefined;
    const sessions_name = try std.fmt.bufPrint(
        &sessions_name_buffer,
        "transient-sessions-{s}",
        .{@tagName(sample)},
    );
    var workspace_name_buffer: [48]u8 = undefined;
    const workspace_name = try std.fmt.bufPrint(
        &workspace_name_buffer,
        "transient-workspace-{s}",
        .{@tagName(sample)},
    );
    try root.createDir(io, sessions_name, .default_dir);
    try root.createDir(io, workspace_name, .default_dir);
    var sessions = try root.openDir(io, sessions_name, .{});
    defer sessions.close(io);
    var workspace = try root.openDir(io, workspace_name, .{});
    defer workspace.close(io);
    try initGitWorktree(workspace, io);

    var database_path_buffer: [256]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &database_path_buffer,
        "{s}/transient-{s}.sqlite3",
        .{ root_path, @tagName(sample) },
    );
    var workspace_path_buffer: [256]u8 = undefined;
    const workspace_path = try std.fmt.bufPrint(
        &workspace_path_buffer,
        "{s}/{s}",
        .{ root_path, workspace_name },
    );
    var owner = try host_store.StorageOwner.open(io, database_path, .{});
    defer owner.close();
    const scratch = try session_store.allocateTransientScratch(std.heap.page_allocator);
    defer session_store.destroyTransientScratch(std.heap.page_allocator, io, scratch);
    var session = try session_store.Session.create(sessions, scratch, &owner, io, .{
        .workspace_path = workspace_path,
        .model = "fixture:density",
        .task = task,
    });
    defer session.close();

    const response_ref: u64 = std.math.maxInt(u32) + 1;
    var writer = try session.beginContent(response_ref);
    errdefer writer.abort();
    const response_bytes: usize = switch (sample) {
        .ordinary => ordinary: {
            var encoded_buffer: [256]u8 = undefined;
            const encoded = try model_protocol.encodeText(
                &encoded_buffer,
                "The failing test is fixed.",
            );
            try writer.append(encoded);
            break :ordinary encoded.len;
        },
        .maximum_model_response => maximum: {
            var window: [host_store.content_window_bytes]u8 = @splat('x');
            var remaining: usize = model_protocol.max_response_size;
            while (remaining != 0) {
                const count = @min(remaining, window.len);
                try writer.append(window[0..count]);
                remaining -= count;
            }
            break :maximum model_protocol.max_response_size;
        },
    };
    try writer.finish();
    var reader = try session.viewContent(response_ref);
    const spool_file_bytes = try session.transientScratchOccupancy();
    if (reader.length() != response_bytes or spool_file_bytes != response_bytes) {
        return error.TransientScratchMeasurementMismatch;
    }

    _ = try owner.memoryAccounting(true);
    _ = try owner.physicalAccounting(true);
    _ = try session.appendConversation(.assistant_text, response_ref, null);
    var transaction: session_transition.Transaction = .{ .sequence = 2, .fact_count = 1 };
    transaction.facts[0] = session_transition.conversationAdvanced(.{
        .agent = .{
            .agent_id = session.agent_id,
            .agent_generation = 1,
            .ownership_epoch = session.ownership_epoch,
        },
        .entry_id = 2,
        .parent_id = 1,
        .kind = .assistant_text,
        .content_ref = response_ref,
    });
    _ = try session.commitSemantic(&.{transaction.facts[0]}, null);
    const memory = try owner.memoryAccounting(false);
    const physical = try owner.physicalAccounting(false);
    var line: [512]u8 = undefined;
    const encoded = try std.fmt.bufPrint(
        &line,
        "{{\"sample\":\"{s}\",\"response_bytes\":{d},\"disk_backed_spool_occupancy_bytes\":{d},\"content_import_window_resident_bytes\":{d},\"theoretical_single_content_bound_bytes\":{d},\"theoretical_session_spool_bound_bytes\":{d},\"transient_scratch_metadata_allocation_bytes\":{d},\"transient_scratch_metadata_at_active_capacity_100_bytes\":{d},\"sqlite_page_writes\":{d},\"sqlite_cache_spills\":{d},\"sqlite_heap_highwater_bytes\":{d}}}\n",
        .{
            sample.name(),
            reader.length(),
            spool_file_bytes,
            host_store.content_window_bytes,
            host_store.max_content_bytes,
            session_store.max_transient_scratch_bytes,
            session_store.transient_scratch_allocation_bytes,
            session_store.transient_scratch_allocation_bytes * 100,
            physical.cache_page_writes,
            physical.cache_spills,
            memory.heap_highwater_bytes,
        },
    );
    try std.Io.File.stdout().writeStreamingAll(io, encoded);
}

fn measureMaximumSessionScratch(
    io: std.Io,
    root: std.Io.Dir,
    root_path: []const u8,
) !void {
    try root.createDir(io, "maximum-session-workspace", .default_dir);
    var workspace = try root.openDir(io, "maximum-session-workspace", .{});
    defer workspace.close(io);
    try initGitWorktree(workspace, io);

    var database_path_buffer: [256]u8 = undefined;
    const database_path = try std.fmt.bufPrint(
        &database_path_buffer,
        "{s}/maximum-session.sqlite3",
        .{root_path},
    );
    var workspace_path_buffer: [256]u8 = undefined;
    const workspace_path = try std.fmt.bufPrint(
        &workspace_path_buffer,
        "{s}/maximum-session-workspace",
        .{root_path},
    );
    var owner = try host_store.StorageOwner.open(io, database_path, .{});
    defer owner.close();
    const scratch = try session_store.allocateTransientScratch(std.heap.page_allocator);
    defer session_store.destroyTransientScratch(std.heap.page_allocator, io, scratch);
    var session = try session_store.Session.create(root, scratch, &owner, io, .{
        .workspace_path = workspace_path,
        .model = "fixture:density",
        .task = task,
    });
    defer session.close();

    var window: [host_store.content_window_bytes]u8 = @splat('x');
    var facts: [session_store.max_pending_content]session_transition.Fact = undefined;
    const agent: session_transition.AgentContext = .{
        .agent_id = session.agent_id,
        .agent_generation = 1,
        .ownership_epoch = session.ownership_epoch,
    };
    for (0..session_store.max_pending_content) |index| {
        const reference = @as(u64, std.math.maxInt(u32)) + 100 + index;
        var writer = try session.beginContent(reference);
        errdefer writer.abort();
        var remaining: usize = host_store.max_content_bytes;
        while (remaining != 0) {
            const count = @min(remaining, window.len);
            try writer.append(window[0..count]);
            remaining -= count;
        }
        try writer.finish();
        facts[index] = session_transition.outcome(agent, index + 1, reference);
    }
    const spool_occupancy = try session.transientScratchOccupancy();
    if (spool_occupancy != session_store.max_transient_scratch_bytes) {
        return error.TransientScratchMeasurementMismatch;
    }

    _ = try owner.memoryAccounting(true);
    _ = try owner.physicalAccounting(true);
    _ = try session.commitSemantic(&facts, null);
    const memory = try owner.memoryAccounting(false);
    const physical = try owner.physicalAccounting(false);
    var line: [768]u8 = undefined;
    const encoded = try std.fmt.bufPrint(
        &line,
        "{{\"sample\":\"maximum_live_session_spool_transient\",\"pending_values\":{d},\"bytes_per_value\":{d},\"disk_backed_spool_occupancy_bytes\":{d},\"content_import_window_resident_bytes\":{d},\"transient_scratch_metadata_allocation_bytes\":{d},\"transient_scratch_metadata_at_active_capacity_100_bytes\":{d},\"sqlite_page_writes\":{d},\"sqlite_cache_spills\":{d},\"sqlite_heap_highwater_bytes\":{d}}}\n",
        .{
            session_store.max_pending_content,
            host_store.max_content_bytes,
            spool_occupancy,
            host_store.content_window_bytes,
            session_store.transient_scratch_allocation_bytes,
            session_store.transient_scratch_allocation_bytes * 100,
            physical.cache_page_writes,
            physical.cache_spills,
            memory.heap_highwater_bytes,
        },
    );
    try std.Io.File.stdout().writeStreamingAll(io, encoded);
}

fn initGitWorktree(dir: std.Io.Dir, io: std.Io) !void {
    try dir.createDir(io, ".git", .default_dir);
    var git_dir = try dir.openDir(io, ".git", .{});
    defer git_dir.close(io);
    try git_dir.createDir(io, "objects", .default_dir);
    try git_dir.createDir(io, "refs", .default_dir);
    var config = try git_dir.createFile(io, "config", .{});
    defer config.close(io);
    try config.writePositionalAll(io, "[core]\n\trepositoryformatversion = 0\n", 0);
    var head = try git_dir.createFile(io, "HEAD", .{});
    defer head.close(io);
    try head.writePositionalAll(io, "ref: refs/heads/main\n", 0);
}

fn fileSize(io: std.Io, path: []const u8) !u64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    return (try file.stat(io)).size;
}

fn fileAllocatedBytes(io: std.Io, path: []const u8) !u64 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var status: c.struct_stat = undefined;
    if (c.fstat(@intCast(file.handle), &status) != 0) {
        return error.FileStatusUnavailable;
    }
    return @as(u64, @intCast(status.st_blocks)) * 512;
}

fn processUsage() !ProcessUsage {
    var info: c.struct_rusage_info_v2 = undefined;
    if (c.proc_pid_rusage(
        c.getpid(),
        c.RUSAGE_INFO_V2,
        @ptrCast(&info),
    ) != 0) return error.ProcessUsageUnavailable;
    return .{
        .disk_read_bytes = info.ri_diskio_bytesread,
        .disk_write_bytes = info.ri_diskio_byteswritten,
        .physical_footprint_bytes = info.ri_phys_footprint,
    };
}

fn percentile(sorted: []const u64, percent: u64) u64 {
    std.debug.assert(sorted.len != 0);
    const rank = (percent * sorted.len + 99) / 100;
    return sorted[@max(rank, 1) - 1];
}

fn residentBytes() !u64 {
    var info: c.struct_proc_taskinfo = undefined;
    const actual = c.proc_pidinfo(
        c.getpid(),
        c.PROC_PIDTASKINFO,
        0,
        &info,
        @sizeOf(c.struct_proc_taskinfo),
    );
    if (actual != @sizeOf(c.struct_proc_taskinfo)) return error.ProcessInfoUnavailable;
    return info.pti_resident_size;
}
