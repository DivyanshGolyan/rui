const std = @import("std");
const c = @cImport({
    @cInclude("libproc.h");
    @cInclude("sys/resource.h");
    @cInclude("unistd.h");
});

/// Whole-process observations reported by macOS. These deliberately sit next
/// to, rather than replace, OnePage's logical resource ledgers: they include
/// allocator overhead, SQLite, libc, linked libraries, stacks, and operating
/// system accounting that struct-size arithmetic cannot see.
pub const Sample = struct {
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

pub fn sample() !Sample {
    var task: c.struct_proc_taskinfo = undefined;
    const task_bytes = c.proc_pidinfo(
        c.getpid(),
        c.PROC_PIDTASKINFO,
        0,
        &task,
        @sizeOf(c.struct_proc_taskinfo),
    );
    if (task_bytes != @sizeOf(c.struct_proc_taskinfo)) return error.ProcessInfoUnavailable;

    var usage: c.struct_rusage_info_v4 = undefined;
    const usage_result = c.proc_pid_rusage(
        c.getpid(),
        c.RUSAGE_INFO_V4,
        @ptrCast(&usage),
    );
    if (usage_result != 0) return error.ProcessUsageUnavailable;

    return .{
        .resident_bytes = task.pti_resident_size,
        .physical_footprint_bytes = usage.ri_phys_footprint,
        .lifetime_peak_physical_footprint_bytes = usage.ri_lifetime_max_phys_footprint,
        .virtual_bytes = task.pti_virtual_size,
        .thread_count = @intCast(task.pti_threadnum),
        .running_thread_count = @intCast(task.pti_numrunning),
        .user_cpu_ns = usage.ri_user_time,
        .system_cpu_ns = usage.ri_system_time,
        .package_idle_wakeups = usage.ri_pkg_idle_wkups,
        .interrupt_wakeups = usage.ri_interrupt_wkups,
        .pageins = usage.ri_pageins,
        .disk_read_bytes = usage.ri_diskio_bytesread,
        .disk_written_bytes = usage.ri_diskio_byteswritten,
        .instructions = usage.ri_instructions,
        .cycles = usage.ri_cycles,
    };
}

test "whole-process sample reports usable macOS counters" {
    const value = try sample();
    try std.testing.expect(value.resident_bytes > 0);
    try std.testing.expect(value.physical_footprint_bytes > 0);
    try std.testing.expect(value.lifetime_peak_physical_footprint_bytes >= value.physical_footprint_bytes);
    try std.testing.expect(value.virtual_bytes >= value.resident_bytes);
    try std.testing.expect(value.thread_count > 0);
}
