//! What the overview's counts line says of live memory: `rui`, this TUI
//! plus its Host, and `tools`, every process the Host runs below it. Values
//! in, totals out; the shell's native readers answer for each process.

const std = @import("std");

/// Live physical memory: `rui` is this TUI plus its Host; `tools` the
/// processes the Host runs, null while none runs.
pub const Memory = struct { rui: u64, tools: ?u64 };

/// The most tool processes one read counts, and the most children it reads
/// of each.
pub const max_tools = 256;

/// Totals for the TUI `self` and its Host `host`, null when none is known.
/// `source` answers `footprint(pid) ?u64` and `children(pid, buffer)
/// ?[]const i32`, each null once the process is gone. The walk goes down
/// from the Host, counts each process once, and stops at `max_tools`.
pub fn read(source: anytype, self: i32, host: ?i32) Memory {
    var rui = source.footprint(self) orelse 0;
    const root = host orelse return .{ .rui = rui, .tools = null };
    rui +|= source.footprint(root) orelse return .{ .rui = rui, .tools = null };

    // Breadth first: `seen` holds every pid met, the walk reads them in turn.
    var seen: [max_tools + 1]i32 = undefined;
    seen[0] = root;
    var count: usize = 1;
    var next: usize = 0;
    var tools: u64 = 0;
    var counted: usize = 0;
    var children: [max_tools]i32 = undefined;
    while (next < count) : (next += 1) {
        const pid = seen[next];
        if (next != 0) {
            // A tool gone since its parent listed it counts for nothing.
            tools +|= source.footprint(pid) orelse continue;
            counted += 1;
        }
        const listed = source.children(pid, &children) orelse continue;
        for (listed) |child| {
            if (count == seen.len) break;
            if (std.mem.indexOfScalar(i32, seen[0..count], child) != null) continue;
            seen[count] = child;
            count += 1;
        }
    }
    return .{ .rui = rui, .tools = if (counted == 0) null else tools };
}

test "rui adds this TUI and its Host, and tools add every process below the Host" {
    // Host 10 runs two Bash calls; one of them runs a compiler with a child.
    var source: Fake = .{ .processes = &.{
        .{ .pid = 1, .bytes = 20 * mb },
        .{ .pid = 10, .bytes = 24 * mb, .children = &.{ 11, 12 } },
        .{ .pid = 11, .bytes = 3 * mb },
        .{ .pid = 12, .bytes = 900 * mb, .children = &.{13} },
        .{ .pid = 13, .bytes = 1000 * mb },
    } };
    try std.testing.expectEqual(Memory{ .rui = 44 * mb, .tools = 1903 * mb }, read(&source, 1, 10));
}

test "with no tool process, or no Host, tools is null; an unreadable Host leaves rui as the TUI" {
    var idle: Fake = .{ .processes = &.{ .{ .pid = 1, .bytes = 20 * mb }, .{ .pid = 10, .bytes = 24 * mb } } };
    try std.testing.expectEqual(Memory{ .rui = 44 * mb, .tools = null }, read(&idle, 1, 10));
    try std.testing.expectEqual(Memory{ .rui = 20 * mb, .tools = null }, read(&idle, 1, null));
    // The Host exited between the listing and this read.
    try std.testing.expectEqual(Memory{ .rui = 20 * mb, .tools = null }, read(&idle, 1, 99));
}

test "a tool that exits mid-walk is left out, and its listed children with it" {
    var source: Fake = .{
        .processes = &.{
            .{ .pid = 1, .bytes = 20 * mb },
            .{ .pid = 10, .bytes = 24 * mb, .children = &.{ 11, 12 } },
            // 11 is gone: neither its footprint nor its children read.
            .{ .pid = 12, .bytes = 5 * mb },
        },
    };
    try std.testing.expectEqual(Memory{ .rui = 44 * mb, .tools = 5 * mb }, read(&source, 1, 10));
}

test "a process listed twice, or a cycle a reused pid makes, counts once, and the walk stops at its bound" {
    var cycle: Fake = .{ .processes = &.{
        .{ .pid = 1, .bytes = 20 * mb },
        .{ .pid = 10, .bytes = 24 * mb, .children = &.{ 11, 11 } },
        .{ .pid = 11, .bytes = 2 * mb, .children = &.{ 10, 12 } },
        .{ .pid = 12, .bytes = 3 * mb, .children = &.{11} },
    } };
    try std.testing.expectEqual(Memory{ .rui = 44 * mb, .tools = 5 * mb }, read(&cycle, 1, 10));

    // A fan wider than the bound counts the first `max_tools` processes.
    var wide: [max_tools + 10]i32 = undefined;
    var processes: [max_tools + 12]Fake.Process = undefined;
    processes[0] = .{ .pid = 1, .bytes = 1 };
    processes[1] = .{ .pid = 2, .bytes = 1, .children = &wide };
    for (&wide, processes[2..], 0..) |*pid, *process, at| {
        pid.* = @intCast(100 + at);
        process.* = .{ .pid = pid.*, .bytes = 1 };
    }
    var fan: Fake = .{ .processes = &processes };
    try std.testing.expectEqual(Memory{ .rui = 2, .tools = max_tools }, read(&fan, 1, 2));
}

test "totals saturate rather than wrap" {
    var source: Fake = .{ .processes = &.{
        .{ .pid = 1, .bytes = std.math.maxInt(u64) },
        .{ .pid = 10, .bytes = 1, .children = &.{ 11, 12 } },
        .{ .pid = 11, .bytes = std.math.maxInt(u64) },
        .{ .pid = 12, .bytes = 1 },
    } };
    try std.testing.expectEqual(Memory{ .rui = std.math.maxInt(u64), .tools = std.math.maxInt(u64) }, read(&source, 1, 10));
}

const mb = 1024 * 1024;

/// A process table: each pid's footprint and direct children.
const Fake = struct {
    processes: []const Process,

    const Process = struct { pid: i32, bytes: u64, children: []const i32 = &.{} };

    fn find(self: *const Fake, pid: i32) ?Process {
        for (self.processes) |process| if (process.pid == pid) return process;
        return null;
    }

    pub fn footprint(self: *Fake, pid: i32) ?u64 {
        return (self.find(pid) orelse return null).bytes;
    }

    pub fn children(self: *Fake, pid: i32, buffer: []i32) ?[]const i32 {
        const listed = (self.find(pid) orelse return null).children;
        const kept = @min(listed.len, buffer.len);
        @memcpy(buffer[0..kept], listed[0..kept]);
        return buffer[0..kept];
    }
};
