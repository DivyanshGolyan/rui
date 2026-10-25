//! Private integration-only owner observations. No retries, reader acknowledgments,
//! or diagnostic custody: a lost observation fails evidence, never semantic work.
const std = @import("std");
const c = @import("posix");
const Self = @This();
const TestHold = struct {
    var before_retirement: ?*const fn () void = null;
    var before_sealed_loss: ?*const fn () void = null;
};

pub const Plan = enum { control, control_peers, status, stop, list, transport, dispatch, capture, recovery, managed, bash_cleanup, bash_pipes, execution, sqlite };
pub const record_bytes = 512; // POSIX minimum atomic pipe-write size.
const header_bytes = 28;
// Fixture-owned unlinked backing. Fixture mutation is only atomic admission
// sealing; immutable final readback survives SIGKILL without a footer or ack.
const Shared = extern struct {
    version: u64,
    process: u64,
    run: u64,
    state: std.atomic.Value(u64),
    active: std.atomic.Value(u64),
};
pub const state_bytes = @sizeOf(Shared);
// Fixture disposal revokes publication admission, not semantic work. Existing
// handles retain their low-bit count; a selected attempt after sealing is loss.
pub const sealed = @as(u64, 1) << 63;
// Stable private fixture IDs. Keep encoded meanings independent of Record's
// declaration order; tests/ci/test_harness_contracts.py checks the Python codec.
const FieldId = enum(u8) {
    rui_test_phase = 0,
    at_ns = 1,
    subject_kind = 2,
    subject = 3,
    turn = 4,
    operation = 5,
    attempt = 6,
    action = 7,
    scratch_used_bytes = 8,
    command_key = 9,
    kind = 10,
    control_key = 11,
    store_queued_at_ns = 12,
    lock_acquired_at_ns = 13,
    store_complete_at_ns = 14,
    reply_complete_at_ns = 15,
    queue_wait_ns = 16,
    store_lock_wait_ns = 17,
    store_service_ns = 18,
    post_commit_reply_ns = 19,
    host_total_ns = 20,
    start_ns = 21,
    wait_ns = 22,
    custody_occupied = 23,
    written_bytes = 24,
    http_version = 25,
    connection_id = 26,
    new_connections = 27,
    work_bytes = 28,
    work_items = 29,
    request_bytes = 30,
    process_memory_current_bytes = 31,
    process_memory_highwater_bytes = 32,
    cache_used_bytes = 33,
    cache_spills = 34,
    hard_heap_limit_bytes = 35,
    page_size_bytes = 36,
    cache_size_setting = 37,
    cache_spill_threshold = 38,
    mmap_size_bytes = 39,
    synchronous = 40,
    temp_store = 41,
    busy_timeout_ms = 42,
    journal_mode = 43,
};
const Record = struct {
    rui_test_phase: []const u8,
    subject_kind: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    at_ns: ?[]const u8 = null,
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
    custody_occupied: ?[]const u8 = null,
    written_bytes: ?[]const u8 = null,
    http_version: ?i64 = null,
    connection_id: ?i64 = null,
    new_connections: ?i64 = null,
    work_bytes: ?[]const u8 = null,
    work_items: ?[]const u8 = null,
    request_bytes: ?[]const u8 = null,
    process_memory_current_bytes: ?i64 = null,
    process_memory_highwater_bytes: ?i64 = null,
    cache_used_bytes: ?i64 = null,
    cache_spills: ?i64 = null,
    hard_heap_limit_bytes: ?i64 = null,
    page_size_bytes: ?i64 = null,
    cache_size_setting: ?i64 = null,
    cache_spill_threshold: ?i64 = null,
    mmap_size_bytes: ?i64 = null,
    synchronous: ?i64 = null,
    temp_store: ?i64 = null,
    busy_timeout_ms: ?i64 = null,
    journal_mode: ?[]const u8 = null,
};

comptime {
    // Neither a new parsed field without an ID nor a stale ID may be silent.
    if (std.meta.fieldNames(Record).len != std.meta.fieldNames(FieldId).len)
        @compileError("observation fields and IDs differ");
    for (std.meta.fieldNames(Record)) |name| {
        if (!@hasField(FieldId, name)) @compileError("observation field has no stable ID");
    }
}

fd: c_int,
plan: Plan,
run: u64,
// Reserve sequence and snapshot sticky loss in one atomic operation. Arrival
// may be reordered by descheduling; collectors order by this sequence.
shared: *Shared,
lifecycle_due: std.atomic.Value(bool) = .init(true),
stop_classification_due: std.atomic.Value(bool) = .init(false),
dispatch_boundary_due: std.atomic.Value(bool) = .init(true),

pub fn init(fd: c_int, state_fd: c_int, plan: Plan, run: u64) !Self {
    if (state_fd <= 2 or state_fd == fd) return error.InvalidTestObservationDescriptor;
    defer _ = c.close(state_fd);
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
    if (c.fstat(state_fd, &info) != 0 or info.st_mode & c.S_IFMT != c.S_IFREG or info.st_size != state_bytes)
        return error.InvalidTestObservationDescriptor;
    const address = c.mmap(null, state_bytes, c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, state_fd, 0);
    if (address == c.MAP_FAILED) return error.InvalidTestObservationDescriptor;
    const shared: *Shared = @ptrCast(@alignCast(address));
    shared.* = .{ .version = 1, .process = @intCast(c.getpid()), .run = run, .state = .init(0), .active = .init(0) };
    return .{ .fd = fd, .plan = plan, .run = run, .shared = shared };
}

pub fn close(self: *Self) void {
    _ = c.close(self.fd);
    _ = c.munmap(self.shared, state_bytes);
}

// Selection uses owning native values, before optional JSON construction.
pub fn begin(self: *Self, phase: []const u8, subject: ?[]const u8) ?Publication {
    if (!self.selected(phase, subject)) return null;
    const previous = self.shared.active.fetchAdd(1, .acq_rel);
    if (previous & sealed != 0) {
        // Increment first: SIGKILL before sticky loss still leaves custody.
        // No observer acknowledgment, wait or effect on semantic execution.
        if (@import("builtin").is_test) if (TestHold.before_sealed_loss) |hold| hold();
        _ = self.shared.state.fetchOr(1, .acq_rel);
        _ = self.shared.active.fetchSub(1, .acq_rel);
        return null;
    }
    return .{ .owner = self };
}

pub const Publication = struct {
    owner: ?*Self,

    pub fn record(self: *Publication, json: []const u8) void {
        const owner = self.owner.?;
        owner.record(json);
        if (@import("builtin").is_test) if (TestHold.before_retirement) |hold| hold();
        // Native custody ends before optional stderr can be attempted.
        self.owner = null;
        _ = owner.shared.active.fetchSub(1, .acq_rel);
    }

    pub fn finish(self: *Publication) void {
        const owner = self.owner orelse return;
        self.owner = null;
        _ = owner.shared.state.fetchOr(1, .acq_rel);
        _ = owner.shared.active.fetchSub(1, .acq_rel);
    }
};

fn selected(self: *Self, phase: []const u8, subject: ?[]const u8) bool {
    if (self.plan == .sqlite) return std.mem.eql(u8, phase, "sqlite_diagnostic");
    if (self.plan == .execution) {
        // Every service boundary and every interval endpoint: gaps are derived
        // from the complete sequence, so no sampling.
        inline for (.{ "lifecycle_boundary", "preparation_started", "preparation_completed", "preparation_advance_started", "preparation_advance_completed", "preparation_advance_failed", "validation_started", "validation_completed", "validation_failed", "settlement_lock_requested", "settlement_complete" }) |name| {
            if (std.mem.eql(u8, phase, name)) return true;
        }
        return false;
    }
    if (self.plan == .bash_cleanup) {
        inline for (.{ "cleanup_started", "cleanup_release_observed", "cleanup_completed", "inspection_captured" }) |name| {
            if (std.mem.eql(u8, phase, name)) return true;
        }
        return false;
    }
    if (self.plan == .bash_pipes) {
        return std.mem.eql(u8, phase, "bash_leader_observed_with_open_pipes") or
            std.mem.eql(u8, phase, "control_store_complete");
    }
    if (self.plan == .capture) {
        inline for (.{ "capture_write_gate_entered", "transport_resume_capture_failure", "effect_stop_requested" }) |name| {
            if (std.mem.eql(u8, phase, name)) return true;
        }
        return false;
    }
    if (self.plan == .recovery) {
        inline for (.{ "prepared_before_handoff", "action_attempt_admitted", "action_result_ready", "action_result_committed" }) |name| {
            if (std.mem.eql(u8, phase, name)) return true;
        }
        return false;
    }
    if (self.plan == .managed) {
        inline for (.{ "preparation_completed", "prepared_before_handoff", "codex_transfer" }) |name| {
            if (std.mem.eql(u8, phase, name)) return true;
        }
        return false;
    }
    if (self.plan == .dispatch) {
        if (std.mem.eql(u8, phase, "preparation_advance_completed"))
            return self.dispatch_boundary_due.swap(false, .acq_rel);
        inline for (.{ "connection_request_session_stop", "connection_request_permission_decision", "control_store_queued", "control_lock_acquired", "control_gate_released", "exhausted_retry_recovery_held" }) |name| {
            if (std.mem.eql(u8, phase, name)) return true;
        }
        return false;
    }
    const connection = std.mem.startsWith(u8, phase, "connection_request_") or
        std.mem.eql(u8, phase, "connection_resources_released");
    if (self.plan == .list or self.plan == .transport) return connection;
    if (self.plan == .control_peers and (connection or
        std.mem.eql(u8, phase, "connection_place_released"))) return true;
    if (std.mem.eql(u8, phase, "lifecycle_boundary"))
        return self.plan != .stop and self.lifecycle_due.swap(false, .acq_rel);
    if (self.plan == .status) return connection or
        std.mem.eql(u8, phase, "action_attempt_admitted") or
        std.mem.eql(u8, phase, "ordinary_classification_released") or
        std.mem.eql(u8, phase, "connection_place_released");
    if (self.plan == .stop) {
        if (std.mem.eql(u8, phase, "connection_request_host_stop")) {
            self.stop_classification_due.store(true, .release);
            return true;
        }
        if (std.mem.eql(u8, phase, "ordinary_classification_released"))
            return std.mem.eql(u8, subject orelse "", "message") or
                std.mem.eql(u8, subject orelse "", "configure") or
                (std.mem.eql(u8, subject orelse "", "observe") and
                    self.stop_classification_due.load(.acquire));
        return std.mem.eql(u8, phase, "connection_resources_released") or
            std.mem.eql(u8, phase, "connection_request_message") or
            std.mem.eql(u8, phase, "connection_request_configure") or
            std.mem.eql(u8, phase, "test_gate_waiting") or
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

fn record(self: *Self, json: []const u8) void {
    // Fixed decoding storage only when explicitly enabled. Internal trace
    // construction is trusted; malformed/oversized instrumentation is loss.
    var decoding: [2048]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&decoding);
    const parsed = std.json.parseFromSlice(Record, allocator.allocator(), json, .{
        .ignore_unknown_fields = true,
    }) catch {
        _ = self.shared.state.fetchOr(1, .acq_rel);
        return;
    };
    defer parsed.deinit();
    var bytes: [record_bytes]u8 = undefined;
    var length: usize = header_bytes;
    inline for (comptime std.meta.fieldNames(FieldId)) |name| {
        var number_buffer: [20]u8 = undefined;
        const value: ?[]const u8 = if (@FieldType(Record, name) == ?i64)
            if (@field(parsed.value, name)) |number| std.fmt.bufPrint(&number_buffer, "{d}", .{number}) catch unreachable else null
        else
            @field(parsed.value, name);
        if (value) |text| {
            if (length + 3 + text.len > bytes.len) {
                _ = self.shared.state.fetchOr(1, .acq_rel);
                return;
            }
            bytes[length] = @backingInt(@field(FieldId, name));
            std.mem.writeInt(u16, bytes[length + 1 ..][0..2], @intCast(text.len), .little);
            @memcpy(bytes[length + 3 ..][0..text.len], text);
            length += 3 + text.len;
        }
    }
    const state = self.shared.state.fetchAdd(2, .acq_rel);
    std.mem.writeInt(u16, bytes[0..2], @intCast(length), .little);
    bytes[2] = 1;
    bytes[3] = @intCast(state & 1);
    std.mem.writeInt(u64, bytes[4..12], (state >> 1) + 1, .little);
    std.mem.writeInt(u64, bytes[12..20], self.run, .little);
    std.mem.writeInt(u64, bytes[20..28], @intCast(c.getpid()), .little);
    if (c.write(self.fd, &bytes, length) != @as(isize, @intCast(length)))
        _ = self.shared.state.fetchOr(1, .acq_rel);
}

test "private owner observations remain bounded under full and closed credit" {
    var descriptors: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pipe(&descriptors));
    var reader_open = true;
    defer {
        if (reader_open) _ = c.close(descriptors[0]);
    }
    try std.testing.expectEqual(@as(c_int, 0), c.fcntl(descriptors[1], c.F_SETFL, @as(c_int, c.O_NONBLOCK)));
    const backing = c.tmpfile() orelse return error.TestUnexpectedResult;
    defer _ = c.fclose(backing);
    try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(c.fileno(backing), state_bytes));
    const state_fd = c.dup(c.fileno(backing));
    var owner = try Self.init(descriptors[1], state_fd, .status, 37);
    var owner_open = true;
    defer if (owner_open) owner.close();
    const event = "{\"rui_test_phase\":\"ordinary_classification_released\",\"at_ns\":\"1234567\",\"subject_kind\":\"route\",\"subject\":\"message\"}";
    var publication = owner.begin("ordinary_classification_released", "message").?;
    publication.record(event);
    var bytes: [512]u8 = undefined;
    const read = c.read(descriptors[0], &bytes, bytes.len);
    try std.testing.expect(read > header_bytes and read <= record_bytes);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, bytes[4..12], .little));
    try std.testing.expectEqual(@as(u64, 37), std.mem.readInt(u64, bytes[12..20], .little));
    try std.testing.expectEqual(@as(u8, 0), bytes[3]);
    // Independent schema bytes, despite Record declaring at_ns after subject.
    try std.testing.expectEqualSlices(u8, "\x00\x20\x00ordinary_classification_released" ++
        "\x01\x07\x001234567\x02\x05\x00route\x03\x07\x00message", bytes[header_bytes..@intCast(read)]);
    const unselected = "{"; // Native phase is unselected; malformed optional text cannot taint evidence.
    if (owner.begin("lifecycle_service_observation", null)) |initial| {
        var ignored = initial;
        defer ignored.finish();
        ignored.record(unselected);
    }
    try std.testing.expectEqual(@as(u64, 2), owner.shared.state.load(.acquire));
    try std.testing.expectEqual(@as(u64, 0), owner.shared.active.load(.acquire));
    publication = owner.begin("ordinary_classification_released", "message").?;
    try std.testing.expectEqual(@as(u64, 1), owner.shared.active.load(.acquire));
    publication.finish(); // Failed construction before any JSON or sequence.
    try std.testing.expectEqual(@as(u64, 0), owner.shared.active.load(.acquire));
    publication = owner.begin("ordinary_classification_released", "message").?;
    publication.record("{"); // Encoding loss reserves no event and sends no later frame.
    try std.testing.expectEqual(@as(isize, state_bytes), c.pread(c.fileno(backing), &bytes, state_bytes, 0));
    try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, bytes[24..32], .little));
    const filler = @as([record_bytes]u8, @splat('F'));
    var filled: usize = 0;
    while (c.write(descriptors[1], &filler, filler.len) > 0) filled += filler.len;
    try std.testing.expect(filled > 0);
    publication = owner.begin("ordinary_classification_released", "message").?;
    publication.record(event); // No collector/credit and no retry or semantic wait.
    try std.testing.expectEqual(@as(u64, 1), owner.shared.state.load(.acquire) & 1);
    try std.testing.expectEqual(@as(isize, state_bytes), c.pread(c.fileno(backing), &bytes, state_bytes, 0));
    try std.testing.expectEqual(@as(u64, 5), std.mem.readInt(u64, bytes[24..32], .little));
    while (filled > 0) {
        const count = c.read(descriptors[0], &bytes, @min(bytes.len, filled));
        try std.testing.expect(count > 0);
        filled -= @intCast(count);
    }
    publication = owner.begin("ordinary_classification_released", "message").?;
    publication.record(event);
    try std.testing.expect(c.read(descriptors[0], &bytes, bytes.len) > header_bytes);
    try std.testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, bytes[4..12], .little));
    try std.testing.expectEqual(@as(u8, 1), bytes[3]);
    _ = c.close(descriptors[0]);
    reader_open = false;
    publication = owner.begin("ordinary_classification_released", "message").?;
    publication.record(event); // Existing test I/O initialization owns SIGPIPE.
    try std.testing.expectEqual(@as(u64, 1), owner.shared.state.load(.acquire) & 1);
    try std.testing.expect(c.fcntl(descriptors[1], c.F_GETFL) & c.O_NONBLOCK != 0);
    owner.close();
    owner_open = false;
    try std.testing.expectEqual(@as(isize, state_bytes), c.pread(c.fileno(backing), &bytes, state_bytes, 0));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, bytes[0..8], .little));
    try std.testing.expectEqual(@as(u64, @intCast(c.getpid())), std.mem.readInt(u64, bytes[8..16], .little));
    try std.testing.expectEqual(@as(u64, 37), std.mem.readInt(u64, bytes[16..24], .little));
    try std.testing.expectEqual(@as(u64, 9), std.mem.readInt(u64, bytes[24..32], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, bytes[32..40], .little));
}

test "private owner observations preserve selected custody through SIGKILL" {
    inline for (comptime std.meta.tags(Plan)) |plan| {
        const phase = switch (plan) {
            .control, .control_peers => "cleanup_completed",
            .bash_cleanup => "cleanup_release_observed",
            .bash_pipes => "bash_leader_observed_with_open_pipes",
            .dispatch => "control_store_queued",
            .capture => "capture_write_gate_entered",
            .recovery => "action_attempt_admitted",
            .managed => "codex_transfer",
            .execution => "settlement_complete",
            .sqlite => "sqlite_diagnostic",
            .list, .transport, .status, .stop => "connection_resources_released",
        };
        for ([_]bool{ false, true }) |selected_kill| {
            var descriptors: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), c.pipe(&descriptors));
            defer _ = c.close(descriptors[0]);
            try std.testing.expectEqual(@as(c_int, 0), c.fcntl(descriptors[1], c.F_SETFL, @as(c_int, c.O_NONBLOCK)));
            const backing = c.tmpfile() orelse return error.TestUnexpectedResult;
            defer _ = c.fclose(backing);
            try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(c.fileno(backing), state_bytes));
            var owner = try Self.init(descriptors[1], c.dup(c.fileno(backing)), plan, 37);
            defer owner.close();
            var publication = owner.begin(phase, null).?;
            var json: [128]u8 = undefined;
            publication.record(try std.fmt.bufPrint(&json, "{{\"rui_test_phase\":\"{s}\"}}", .{phase}));
            var bytes: [512]u8 = undefined;
            try std.testing.expect(c.read(descriptors[0], &bytes, bytes.len) > header_bytes);
            var ready: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), c.pipe(&ready));
            defer _ = c.close(ready[0]);
            defer _ = c.close(ready[1]);
            const pid = c.fork();
            try std.testing.expect(pid >= 0);
            if (pid == 0) {
                // Only fixed native selection/atomic operations after fork.
                _ = owner.begin(if (selected_kill) phase else "lifecycle_service_observation", null);
                if (c.write(ready[1], "R", 1) != 1) c._exit(1);
                while (true) _ = c.pause();
            }
            var reaped = false;
            defer if (!reaped) {
                _ = c.kill(pid, c.SIGKILL);
                _ = c.waitpid(pid, null, 0);
            };
            try std.testing.expectEqual(@as(isize, 1), c.read(ready[0], &bytes, 1));
            try std.testing.expectEqual(@as(c_int, 0), c.kill(pid, c.SIGKILL));
            var status: c_int = 0;
            try std.testing.expectEqual(pid, c.waitpid(pid, &status, 0));
            reaped = true;
            try std.testing.expect(c.WIFSIGNALED(status) and c.WTERMSIG(status) == c.SIGKILL);
            try std.testing.expectEqual(@as(isize, state_bytes), c.pread(c.fileno(backing), &bytes, state_bytes, 0));
            // The complete selected prefix survives both kills. Only a selected
            // unfinished construction invalidates that prefix after reap.
            try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, bytes[24..32], .little));
            try std.testing.expectEqual(@as(u64, @intFromBool(selected_kill)), std.mem.readInt(u64, bytes[32..40], .little));
        }
    }
}

test "private owner observations seal admission without forgiving held or late publication" {
    const Hold = struct {
        var ready: c_int = undefined;
        var release: c_int = undefined;
        fn wait() void {
            if (c.write(ready, "R", 1) != 1) c._exit(91);
            var byte: [1]u8 = undefined;
            if (c.read(release, &byte, 1) != 1) c._exit(92);
        }
    };
    inline for (comptime std.meta.tags(Plan)) |plan| {
        const phase = switch (plan) {
            .control, .control_peers => "cleanup_completed",
            .bash_cleanup => "cleanup_release_observed",
            .bash_pipes => "bash_leader_observed_with_open_pipes",
            .dispatch => "control_store_queued",
            .capture => "capture_write_gate_entered",
            .recovery => "action_attempt_admitted",
            .managed => "codex_transfer",
            .execution => "settlement_complete",
            .sqlite => "sqlite_diagnostic",
            .list, .transport, .status, .stop => "connection_resources_released",
        };
        for (0..3) |kind| {
            var descriptors: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), c.pipe(&descriptors));
            defer _ = c.close(descriptors[0]);
            try std.testing.expectEqual(@as(c_int, 0), c.fcntl(descriptors[1], c.F_SETFL, @as(c_int, c.O_NONBLOCK)));
            const backing = c.tmpfile() orelse return error.TestUnexpectedResult;
            defer _ = c.fclose(backing);
            try std.testing.expectEqual(@as(c_int, 0), c.ftruncate(c.fileno(backing), state_bytes));
            var owner = try Self.init(descriptors[1], c.dup(c.fileno(backing)), plan, 37);
            defer owner.close();
            var ready: [2]c_int = undefined;
            var release: [2]c_int = undefined;
            try std.testing.expectEqual(@as(c_int, 0), c.pipe(&ready));
            defer _ = c.close(ready[0]);
            defer _ = c.close(ready[1]);
            try std.testing.expectEqual(@as(c_int, 0), c.pipe(&release));
            defer _ = c.close(release[0]);
            defer _ = c.close(release[1]);
            if (kind == 2) _ = owner.shared.active.fetchOr(sealed, .acq_rel);
            var json: [128]u8 = undefined;
            const event = try std.fmt.bufPrint(&json, "{{\"rui_test_phase\":\"{s}\"}}", .{phase});
            const pid = c.fork();
            try std.testing.expect(pid >= 0);
            if (pid == 0) {
                Hold.ready = ready[1];
                Hold.release = release[0];
                if (kind == 2) TestHold.before_sealed_loss = Hold.wait else TestHold.before_retirement = Hold.wait;
                var publication = owner.begin(phase, null).?;
                publication.record(event);
                c._exit(0);
            }
            var reaped = false;
            defer if (!reaped) {
                _ = c.kill(pid, c.SIGKILL);
                _ = c.waitpid(pid, null, 0);
            };
            var bytes: [512]u8 = undefined;
            var ready_poll = c.struct_pollfd{ .fd = ready[0], .events = c.POLLIN, .revents = 0 };
            try std.testing.expectEqual(@as(c_int, 1), c.poll(&ready_poll, 1, 3000));
            try std.testing.expectEqual(@as(isize, 1), c.read(ready[0], &bytes, 1));
            if (kind != 2) {
                // The entire last frame is already observable, but its actual
                // Publication.record call has not retired custody.
                try std.testing.expect(c.read(descriptors[0], &bytes, bytes.len) > header_bytes);
                try std.testing.expectEqual(@as(u64, 1), owner.shared.active.fetchOr(sealed, .acq_rel));
                try std.testing.expectEqual(@as(u64, 2), owner.shared.state.load(.acquire));
            }
            try std.testing.expectEqual(sealed + 1, owner.shared.active.load(.acquire));
            if (kind == 0) {
                try std.testing.expectEqual(@as(isize, 1), c.write(release[1], "x", 1));
            } else {
                try std.testing.expectEqual(@as(c_int, 0), c.kill(pid, c.SIGKILL));
            }
            var status: c_int = 0;
            try std.testing.expectEqual(pid, c.waitpid(pid, &status, 0));
            reaped = true;
            try std.testing.expectEqual(sealed + @intFromBool(kind != 0), owner.shared.active.load(.acquire));
            if (kind == 0) {
                try std.testing.expect(c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0);
                try std.testing.expect(owner.begin(phase, null) == null);
                try std.testing.expectEqual(@as(u64, 3), owner.shared.state.load(.acquire));
                try std.testing.expectEqual(sealed, owner.shared.active.load(.acquire));
            } else {
                try std.testing.expect(c.WIFSIGNALED(status) and c.WTERMSIG(status) == c.SIGKILL);
                // Even interruption before late-attempt loss retains custody.
                try std.testing.expectEqual(@as(u64, if (kind == 1) 2 else 0), owner.shared.state.load(.acquire));
            }
        }
    }
}
