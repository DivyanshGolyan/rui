//! Private integration-only owner observations. No retries, reader acknowledgments,
//! or diagnostic custody: a lost observation fails evidence, never semantic work.
const std = @import("std");
const c = @cImport({
    // The glibc fortified variadic open wrappers cannot be translated by Zig.
    // This module uses only fcntl/fstat/fpathconf/write, not those wrappers.
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
});
const Self = @This();

pub const Plan = enum { control, status, stop, list };
pub const record_bytes = 512; // POSIX minimum atomic pipe-write size.
const header_bytes = 28;
// Field order is the private fixture codec, not a public protocol.
const Record = struct {
    rui_test_phase: []const u8,
    at_ns: ?[]const u8 = null,
    subject_kind: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    turn: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    attempt: ?[]const u8 = null,
    action: ?[]const u8 = null,
    scratch_used_bytes: ?[]const u8 = null,
    command_key: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    control_key: ?[]const u8 = null,
    store_queued_at_ns: ?[]const u8 = null,
    lock_acquired_at_ns: ?[]const u8 = null,
    store_complete_at_ns: ?[]const u8 = null,
    reply_complete_at_ns: ?[]const u8 = null,
    queue_wait_ns: ?[]const u8 = null,
    store_lock_wait_ns: ?[]const u8 = null,
    store_service_ns: ?[]const u8 = null,
    post_commit_reply_ns: ?[]const u8 = null,
    host_total_ns: ?[]const u8 = null,
    start_ns: ?[]const u8 = null,
    wait_ns: ?[]const u8 = null,
};

fd: c_int,
plan: Plan,
run: u64,
// Reserve sequence and snapshot sticky loss in one atomic operation. Arrival
// may be reordered by descheduling; collectors order by this sequence.
state: std.atomic.Value(u64) = .init(0),
lifecycle_due: std.atomic.Value(bool) = .init(true),
stop_classification_due: std.atomic.Value(bool) = .init(false),

pub fn init(fd: c_int, plan: Plan, run: u64) !Self {
    if (fd <= 2) return error.InvalidTestObservationDescriptor;
    const flags = c.fcntl(fd, c.F_GETFL);
    var info: c.struct_stat = undefined;
    if (flags < 0 or flags & c.O_NONBLOCK == 0 or c.fstat(fd, &info) != 0 or
        info.st_mode & c.S_IFMT != c.S_IFIFO or c.fpathconf(fd, c._PC_PIPE_BUF) < record_bytes)
        return error.InvalidTestObservationDescriptor;
    // The fixture transferred this private descriptor, not an fd2 alias. It
    // must not survive exec into effects. Host owns close after writer joins.
    if (c.fcntl(fd, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) != 0)
        return error.InvalidTestObservationDescriptor;
    return .{ .fd = fd, .plan = plan, .run = run };
}

pub fn close(self: *Self) void {
    _ = c.close(self.fd);
}

fn selected(self: *Self, event: Record) bool {
    const phase = event.rui_test_phase;
    const connection = std.mem.startsWith(u8, phase, "connection_request_") or
        std.mem.eql(u8, phase, "connection_resources_released");
    if (self.plan == .list) return connection;
    if (std.mem.eql(u8, phase, "lifecycle_boundary"))
        return self.plan != .stop and self.lifecycle_due.swap(false, .acq_rel);
    if (self.plan == .status) return connection or
        std.mem.eql(u8, phase, "ordinary_classification_released") or
        std.mem.eql(u8, phase, "connection_place_released");
    if (self.plan == .stop) {
        if (std.mem.eql(u8, phase, "connection_request_host_stop")) {
            self.stop_classification_due.store(true, .release);
            return true;
        }
        if (std.mem.eql(u8, phase, "ordinary_classification_released"))
            return std.mem.eql(u8, event.subject orelse "", "observe") and
                self.stop_classification_due.load(.acquire);
        return std.mem.eql(u8, phase, "connection_resources_released") or
            std.mem.eql(u8, phase, "bash_handoff_committed") or
            std.mem.eql(u8, phase, "cleanup_started") or
            std.mem.eql(u8, phase, "cleanup_completed") or
            std.mem.eql(u8, phase, "capture_write_gate_entered");
    }
    if (std.mem.eql(u8, phase, "canonical_handoff_superseded"))
        self.lifecycle_due.store(true, .release);
    inline for (.{ "prepared_before_handoff", "canonical_handoff_superseded", "sealed_before_settlement", "control_hint_suppressed", "control_hint_published", "control_timing", "inspection_captured", "test_gate_waiting", "settlement_lock_acquired", "settlement_complete", "model_settlement_committed", "model_settlement_superseded", "cleanup_started", "cleanup_completed" }) |name| {
        if (std.mem.eql(u8, phase, name)) return true;
    }
    return false;
}

pub fn record(self: *Self, json: []const u8) void {
    // Fixed decoding storage only when explicitly enabled. Internal trace
    // construction is trusted; malformed/oversized instrumentation is loss.
    var decoding: [2048]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&decoding);
    const parsed = std.json.parseFromSlice(Record, allocator.allocator(), json, .{
        .ignore_unknown_fields = true,
    }) catch {
        _ = self.state.fetchOr(1, .acq_rel);
        return;
    };
    defer parsed.deinit();
    if (!self.selected(parsed.value)) return;
    var bytes: [record_bytes]u8 = undefined;
    var length: usize = header_bytes;
    inline for (@typeInfo(Record).@"struct".fields, 0..) |field, index| {
        const value: ?[]const u8 = @field(parsed.value, field.name);
        if (value) |text| {
            if (length + 3 + text.len > bytes.len) {
                _ = self.state.fetchOr(1, .acq_rel);
                return;
            }
            bytes[length] = @intCast(index);
            std.mem.writeInt(u16, bytes[length + 1 ..][0..2], @intCast(text.len), .little);
            @memcpy(bytes[length + 3 ..][0..text.len], text);
            length += 3 + text.len;
        }
    }
    const state = self.state.fetchAdd(2, .acq_rel);
    std.mem.writeInt(u16, bytes[0..2], @intCast(length), .little);
    bytes[2] = 1;
    bytes[3] = @intCast(state & 1);
    std.mem.writeInt(u64, bytes[4..12], (state >> 1) + 1, .little);
    std.mem.writeInt(u64, bytes[12..20], self.run, .little);
    std.mem.writeInt(u64, bytes[20..28], @intCast(c.getpid()), .little);
    if (c.write(self.fd, &bytes, length) != @as(isize, @intCast(length)))
        _ = self.state.fetchOr(1, .acq_rel);
}

test "private owner observations remain bounded under full and closed credit" {
    var descriptors: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&descriptors));
    var reader_open = true;
    defer {
        if (reader_open) _ = c.close(descriptors[0]);
    }
    defer _ = c.close(descriptors[1]);
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(descriptors[1], c.F_SETFL, @as(c_int, c.O_NONBLOCK)));
    var owner = try Self.init(descriptors[1], .status, 37);
    const event = "{\"rui_test_phase\":\"ordinary_classification_released\",\"at_ns\":\"1234567\",\"subject_kind\":\"route\",\"subject\":\"message\"}";
    owner.record(event);
    var bytes: [512]u8 = undefined;
    const read = c.read(descriptors[0], &bytes, bytes.len);
    try std.testing.expect(read > header_bytes and read <= record_bytes);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, bytes[4..12], .little));
    try std.testing.expectEqual(@as(u64, 37), std.mem.readInt(u64, bytes[12..20], .little));
    try std.testing.expectEqual(@as(u8, 0), bytes[3]);
    const filler = [_]u8{'F'} ** record_bytes;
    var filled: usize = 0;
    while (c.write(descriptors[1], &filler, filler.len) > 0) filled += filler.len;
    try std.testing.expect(filled > 0);
    owner.record(event); // No collector/credit and no retry or semantic wait.
    try std.testing.expectEqual(@as(u64, 1), owner.state.load(.acquire) & 1);
    while (filled > 0) {
        const count = c.read(descriptors[0], &bytes, @min(bytes.len, filled));
        try std.testing.expect(count > 0);
        filled -= @intCast(count);
    }
    owner.record(event);
    try std.testing.expect(c.read(descriptors[0], &bytes, bytes.len) > header_bytes);
    try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, bytes[4..12], .little));
    try std.testing.expectEqual(@as(u8, 1), bytes[3]);
    _ = c.close(descriptors[0]);
    reader_open = false;
    owner.record(event); // Existing test I/O initialization owns SIGPIPE.
    try std.testing.expectEqual(@as(u64, 1), owner.state.load(.acquire) & 1);
    try std.testing.expect(c.fcntl(descriptors[1], c.F_GETFL) & c.O_NONBLOCK != 0);
}
