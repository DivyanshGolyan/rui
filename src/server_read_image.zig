const std = @import("std");
const execution = @import("execution.zig");
const Host = @import("server_host.zig").Host;
const store = @import("store.zig");
const InputCapture = @import("InputCapture.zig");
const arguments = @import("read_image_arguments.zig");
const source_file = @import("os/read_image_file.zig");
const action_attempt = @import("action_attempt.zig");
const result_fault = @import("result_fault.zig");
const tool_result = @import("tool_result.zig");
const image_intake = @import("image_intake.zig");
const FileSource = @import("image_file_source.zig").FileSource;

pub const capacity = 16;

const labels: action_attempt.Labels = .{
    .admission = "image read admission",
    .custody = "image read custody",
    .stop = "image read stop",
    .result = "image read result publication",
    .failure = "image read failure publication",
};

const PreparationFailure = union(enum) { ordinary: result_fault.Failure, result_creation: result_fault.Failure };

const Active = struct {
    attempt: action_attempt.Attempt = undefined,
    profile: @import("tool_record.zig").Profile = undefined,
    preparation_failure: ?PreparationFailure = null,
    source: ?std.Io.File = null,
    result: ?*tool_result.Result = null,
    input: store.ActionExecutionInput = undefined,
    path: arguments.Path = .{},
    length: u64 = 0,
    deadline: std.Io.Clock.Timestamp = undefined,
    file_source: FileSource = undefined,

    fn recordFailure(self: *Active, failure: result_fault.Failure) anyerror {
        self.preparation_failure = .{ .ordinary = failure };
        return switch (failure) {
            inline else => |err| err,
        };
    }

    fn recordResultCreationFailure(self: *Active, err: anyerror) anyerror {
        self.preparation_failure = .{ .result_creation = .{ .capture = err } };
        return err;
    }

    fn destroy(self: *Active, host: *Host) void {
        const closing = self.attempt.close();
        if (self.result) |result| result.destroy();
        if (self.source) |source| source.close(host.io);
        host.allocator.destroy(self);
        closing.finish();
    }
};

pub const Calls = struct {
    entries: [capacity]?*Active = @splat(null),

    pub fn any(self: *const Calls) bool {
        for (self.entries) |entry| if (entry != null) return true;
        return false;
    }

    pub fn contains(self: *const Calls, action: u64) bool {
        for (self.entries) |entry| if (entry) |active| {
            if (active.attempt.binding.action_id == action) return true;
        };
        return false;
    }

    pub noinline fn admit(self: *Calls, host: *Host, parts: action_attempt.Parts, call: store.ReadyAction) @import("execution_turn.zig").Admission {
        const entry = for (&self.entries) |*entry| {
            if (entry.* == null) break entry;
        } else return .retry_later;
        const active = host.allocator.create(Active) catch return .retry_later;
        active.* = .{};
        active.attempt = switch (action_attempt.admit(parts, call, 300_000, labels)) {
            .attempt => |attempt| attempt,
            .busy, .refused => {
                host.allocator.destroy(active);
                return .retry_later;
            },
            .none, .unattached => {
                host.allocator.destroy(active);
                return .admitted;
            },
        };
        prepare(host, active) catch |err| {
            switch (active.preparation_failure orelse PreparationFailure{ .ordinary = .{ .source = err } }) {
                .ordinary => |fault| fail(host, active, fault),
                .result_creation => |fault| failInput(host, active, fault),
            }
            active.destroy(host);
            return .admitted;
        };
        entry.* = active;
        return .admitted;
    }

    pub fn service(self: *Calls, host: *Host) bool {
        var progress = false;
        for (&self.entries) |*entry| if (entry.*) |active| {
            switch (active.attempt.stopped()) {
                .fenced => return progress,
                .stopped => settleText(active, .cancelled, "Stopped before this image read completed."),
                .running => if (std.Io.Clock.Timestamp.now(host.io, .awake).raw.nanoseconds >= active.deadline.raw.nanoseconds) {
                    settleText(active, .timed_out, "Image read timed out before its result was saved.");
                } else {
                    const progress_result = active.result.?.stepImage();
                    progress = true;
                    switch (progress_result) {
                        .pending => continue,
                        .failed => |fault| {
                            failInput(host, active, fault);
                            active.destroy(host);
                            entry.* = null;
                            continue;
                        },
                        .kept => {},
                        .rejected => |rejection| {
                            switch (rejection) {
                                .failure => |fault| failInput(host, active, fault),
                                .reason => unreachable,
                            }
                            active.destroy(host);
                            entry.* = null;
                            continue;
                        },
                    }
                    publish(host, active);
                },
            }
            active.destroy(host);
            entry.* = null;
            progress = true;
        };
        return progress;
    }

    pub fn shutdown(self: *Calls, host: *Host) void {
        for (&self.entries) |*entry| if (entry.*) |active| {
            active.destroy(host);
            entry.* = null;
        };
    }
};

/// A completed read cannot be relabelled as a file failure when sealing or
/// publication fails. Recovery reports the original Attempt as indeterminate.
fn publish(host: *Host, active: *Active) void {
    const result = active.result.?;
    const value = switch (result.finish()) {
        .value => |value| value,
        .failed => |failure| {
            if (failure.seal) {
                _ = active.attempt.settle(.{ .fence = .{ .phase = "image snapshot sealing", .fault = failure.failure } });
            } else {
                failInput(host, active, failure.failure);
            }
            return;
        },
    };
    _ = active.attempt.settle(.{ .result = .{ .code = .succeeded, .value = value, .retained = result } });
}

fn settleText(active: *Active, code: store.ActionResolutionCode, text: []const u8) void {
    _ = active.attempt.settle(.{ .text = .{ .code = code, .text = text } });
}

fn failedText(buffer: *[256]u8, err: anyerror) []const u8 {
    return std.fmt.bufPrint(buffer, "Image read failed: {s}.", .{@errorName(err)}) catch unreachable;
}

fn fail(host: *Host, active: *Active, fault: result_fault.Failure) void {
    const err = switch (fault) {
        inline else => |value| value,
    };
    if (host.store.isFenced()) {
        _ = active.attempt.settle(.{ .fence = .{ .phase = "image read canonical input", .fault = fault } });
    } else if (err == error.HostDispatchSuppressed) {
        return;
    } else if (err == error.SupersededByControl) {
        settleText(active, .cancelled, "Stopped before this image read completed.");
    } else if (result_fault.classify(fault) == .storage_full) {
        _ = active.attempt.settle(.{ .failure = .{ .fault = fault, .phase = "image snapshot capture" } });
    } else {
        var buffer: [256]u8 = undefined;
        settleText(active, .failed, failedText(&buffer, err));
    }
}

fn failInput(host: *Host, active: *Active, fault: result_fault.Failure) void {
    if (host.store.isFenced()) {
        _ = active.attempt.settle(.{ .fence = .{ .phase = "image read canonical input", .fault = fault } });
        return;
    }
    switch (result_fault.classify(fault)) {
        .rejected => {
            const err = switch (fault) {
                inline else => |value| value,
            };
            var buffer: [256]u8 = undefined;
            settleText(active, .failed, failedText(&buffer, err));
        },
        .storage_full, .suppressed, .uncertain => _ = active.attempt.settle(.{ .failure = .{ .fault = fault, .phase = "image snapshot capture" } }),
        .superseded => settleText(active, .cancelled, "Stopped before this image read completed."),
    }
}

const Source = struct {
    reader: *store.ContentReader,
    length: u64,
    at: u64 = 0,
    used: usize = 0,
    cursor: usize = 0,
    bytes: [2048]u8 = undefined,

    pub fn peek(self: *Source) !?u8 {
        if (self.cursor == self.used) {
            if (self.at == self.length) return null;
            self.used = try self.reader.read(self.at, &self.bytes);
            if (self.used == 0) return error.ShortCanonicalRead;
            self.at += self.used;
            self.cursor = 0;
        }
        return self.bytes[self.cursor];
    }
    pub fn take(self: *Source) !u8 {
        const byte = (try self.peek()) orelse return error.ShortCanonicalRead;
        self.cursor += 1;
        return byte;
    }
};

fn openSource(context: anytype) !void {
    context.active.source = source_file.open(context.host.io, context.active.input.runner.read_image.workspace.slice(), context.active.path.slice()) catch |err| return context.active.recordFailure(.{ .source = err });
}

noinline fn prepare(host: *Host, active: *Active) !void {
    host.store.readActionExecutionInput(.read_image, active.attempt.binding, &active.input) catch |err| return active.recordFailure(.{ .store = err });
    active.profile = @import("tool_record.zig").Runner.read_image.resultProfile(false);
    var reader: store.ContentReader = undefined;
    reader.open(host.store.openContent(active.input.arguments) catch |err| return active.recordFailure(.{ .store = err }));
    defer reader.close();
    var source: Source = .{ .reader = &reader, .length = active.input.arguments.length };
    if (!(arguments.parse(&source, &active.path) catch |err| return active.recordFailure(.{ .store = err }))) return active.recordFailure(.{ .source = error.InvalidImageArguments });
    const now = std.Io.Clock.Timestamp.now(host.io, .awake);
    active.deadline = now.addDuration(.{ .raw = .fromMilliseconds(@intCast(active.input.timeout_ms)), .clock = .awake });
    switch (active.attempt.launch(.effect, now, .{ .host = host, .active = active }, openSource)) {
        .started => {},
        .authority, .handoff => |err| return if (active.preparation_failure != null) err else active.recordFailure(.{ .store = err }),
    }
    active.length = (active.source.?.stat(host.io) catch |err| return active.recordFailure(.{ .source = err })).size;
    // Keep declared-size rejection ahead of Result allocation and scratch.
    _ = image_intake.preflight(active.length, null, .{}) catch |err| return active.recordFailure(.{ .source = err });
    active.file_source = .{ .io = host.io, .file = active.source.?, .length = active.length };
    active.result = tool_result.Result.create(host, active.attempt.binding.action_id, active.profile) catch |err| return active.recordResultCreationFailure(err);
    switch (active.result.?.beginImage(active.file_source.source(), true)) {
        .pending => {},
        .failed => |fault| return active.recordFailure(fault),
        .rejected => |rejection| switch (rejection) {
            .failure => |fault| return active.recordFailure(fault),
            // One image with no preceding or following text always fits layout.
            .reason => unreachable,
        },
        .kept => unreachable,
    }
}

const TestCase = enum { snapshot, missing, invalid, oversized, stop, stop_between_ticks, background, source_io, result_allocation, empty_allocation, oversized_allocation, capture, seal, publication, shutdown, payload_capacity, index_capacity };

fn unreachableOpen(_: anytype) !void {
    @panic("launch authority was already spent");
}

const TestParts = if (@import("builtin").is_test) @import("server_host_testing.zig").TestParts else void;

test "read_image custody owns snapshot publication stop background and recovery" {
    try testReadImage(&.{ .snapshot, .missing, .invalid, .oversized, .stop, .background, .source_io, .capture, .seal, .publication, .shutdown });
}

test "read_image preflight precedes result allocation and OOM fences" {
    try testReadImage(&.{ .empty_allocation, .oversized_allocation, .result_allocation });
}

test "read_image stop between bounded file reads releases custody" {
    try testReadImage(&.{.stop_between_ticks});
}

test "read_image payload growth exhaustion settles failure and releases custody" {
    try testReadImage(&.{.payload_capacity});
}

test "read_image index creation exhaustion settles failure and releases custody" {
    try testReadImage(&.{.index_capacity});
}

fn testReadImage(cases: []const TestCase) !void {
    if (!source_file.available) return error.SkipZigTest;
    const testing = store.testing;
    const protocol = @import("protocol.zig");
    const retention = @import("output_retention.zig");
    const png = @embedFile("codecs/fixtures/image-input/pixel.png");
    const multi_png = @embedFile("codecs/fixtures/image-input/pixel-multi-window.png");
    for (cases) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var storage: store.Store = undefined;
        try testing.testingSqliteStore(&storage, &tmp, std.testing.io);
        var storage_open = true;
        defer if (storage_open) storage.close() catch unreachable;
        var configure = try testing.completeConfiguration("image-config", "", root, "model-a");
        configure.configuration.tools = try .of(&.{"read_image"});
        configure.configuration.permission_mode.state = .value;
        try configure.configuration.permission_mode.value.set("bypass");
        const session = (try storage.configure(&configure, .{})).accepted.session;
        try testing.submitTestMessage(&storage, &tmp, "image-input", "image-message", session.slice(), "Read an image.");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try store.settleCallsForTesting(&storage, &tmp, model, "image-call", &.{.{
            .item_id = "image-item",
            .name = "read_image",
            .encoded_call_id = "image-call",
            .decoded_call_id = "image-call",
            .encoded_arguments = "{\\\"path\\\":\\\"image.png\\\"}",
            .decoded_arguments = "{\"path\":\"image.png\"}",
        }});
        if (case != .missing) {
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "image.png", .data = if (case == .invalid) "not an image" else if (case == .empty_allocation) "" else if (case == .payload_capacity or case == .stop_between_ticks) multi_png else png });
            if (case == .oversized or case == .oversized_allocation) {
                const file = try tmp.dir.openFile(std.testing.io, "image.png", .{ .mode = .read_write });
                defer file.close(std.testing.io);
                try file.setLength(std.testing.io, (@as(@import("input_media.zig").Limits, .{})).max_bytes + 1);
            }
        }
        const selected = (try storage.nextAction(.read_image, .{ .free_credit = .one, .mcp_open = false })).?;
        const baseline: u64 = if (case == .payload_capacity or case == .index_capacity) 17 else 0;
        var used: std.atomic.Value(u64) = .init(baseline);
        var retained: [2]retention.Entry = @splat(.{});
        const limit: u64 = baseline + switch (case) {
            .payload_capacity => InputCapture.window_bytes + 1,
            .index_capacity => png.len + @import("input_parts.zig").Record.byte_length - 1,
            else => 1024 * 1024,
        };
        var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = limit }, &retained);
        defer queue.cleanupAll();
        var records: [1]execution.CustodyRecord = @splat(.{});
        // The first allocation admits Active; fail Result.create after admission.
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 1 });
        var host: Host = .{ .io = std.testing.io, .allocator = if (case == .result_allocation or case == .empty_allocation or case == .oversized_allocation) failing.allocator() else std.testing.allocator, .lease = undefined, .store = &storage, .retention = &queue, .custody = execution.CustodyPool.initialize(&records) };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, undefined);
        const parts: action_attempt.Parts = .{ .store = &storage, .lifecycle = host.lifecycle, .probes = host.probes, .custody = &host.custody };
        var capture_vtable = std.testing.io.vtable.*;
        var calls: Calls = .{};
        defer calls.shutdown(&host);
        try std.testing.expectEqual(@import("execution_turn.zig").Admission.admitted, calls.admit(&host, parts, selected));
        if (case == .missing or case == .oversized or case == .result_allocation or case == .empty_allocation or case == .oversized_allocation) {
            try std.testing.expect(!calls.any());
        } else {
            const active = calls.entries[0].?;
            try std.testing.expectEqual(@as(usize, 1), parts.custody.occupied());
            try std.testing.expect(calls.contains(selected.action_id));
            switch (active.attempt.launch(.effect, .now(std.testing.io, .awake), {}, unreachableOpen)) {
                .authority => |err| try std.testing.expectEqual(error.DispatchPermitConsumed, err),
                else => return error.TestUnexpectedResult,
            }
            if (case == .payload_capacity or case == .stop_between_ticks) {
                // A real multi-window file must yield before a second read.
                try std.testing.expect(calls.service(&host));
                try std.testing.expect(calls.any());
                try std.testing.expectEqual(@as(u64, InputCapture.window_bytes), active.file_source.offset);
                try std.testing.expectEqual(baseline + InputCapture.window_bytes, used.load(.acquire));
            }
            if (case == .capture) {
                capture_vtable.fileWritePositional = struct {
                    fn write(_: ?*anyopaque, _: std.Io.File, _: []const u8, _: []const []const u8, _: usize, _: u64) std.Io.File.WritePositionalError!usize {
                        return error.InputOutput;
                    }
                }.write;
                active.result.?.capture.?.io.vtable = &capture_vtable;
            }
            if (case == .snapshot) {
                // Replacement after acquisition cannot redirect the snapshot.
                try tmp.dir.rename("image.png", tmp.dir, "original.png", std.testing.io);
                try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "image.png", .data = "replacement" });
            }
            if (case == .stop or case == .stop_between_ticks) {
                var stop = try store.testingCompleteSessionStop("image-stop", session.slice());
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            }
            if (case == .background) try std.testing.expect(storage.backgroundAction(.{ .live_action = selected.action_id }, .{}) == .accepted);
            if (case == .publication) parts.probes.arm(.result_before_commit);
            if (case == .source_io) {
                var source_io = std.testing.io;
                var source_vtable = source_io.vtable.*;
                source_vtable.fileReadPositional = struct {
                    fn read(_: ?*anyopaque, _: std.Io.File, _: []const []u8, _: u64) std.Io.File.ReadPositionalError!usize {
                        return error.InputOutput;
                    }
                }.read;
                source_io.vtable = &source_vtable;
                active.file_source.io = source_io;
                const outcome = active.result.?.stepImage();
                try std.testing.expect(outcome == .failed);
                try std.testing.expect(outcome.failed == .source);
                failInput(&host, active, outcome.failed);
                active.destroy(&host);
                calls.entries[0] = null;
                try std.testing.expect(parts.lifecycle.launchAllowed());
            } else if (case == .seal) {
                const complete = active.result.?.stepImage();
                try std.testing.expect(complete == .kept);
                try active.result.?.capture.?.resources.?.index.setLength(std.testing.io, 0);
                publish(&host, active);
                calls.shutdown(&host);
            } else if (case == .shutdown) {
                _ = parts.lifecycle.advance(.stopping);
                calls.shutdown(&host);
            } else try std.testing.expect(calls.service(&host));
        }
        try std.testing.expect(!calls.any());
        try std.testing.expectEqual(@as(usize, 0), parts.custody.occupied());
        try std.testing.expectEqual(baseline, used.load(.acquire));
        if (case == .result_allocation or case == .capture or case == .seal or case == .publication or case == .shutdown) {
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL", .{selected.action_id}));
            if (case != .shutdown) try std.testing.expect(!parts.lifecycle.launchAllowed());
            if (case == .publication) try std.testing.expect(storage.isFenced());
            // Recovery runs under a fresh Store owner, never through a
            // canonical fault fence or a retained source descriptor.
            try tmp.dir.deleteFile(std.testing.io, "image.png");
            try storage.close();
            storage_open = false;
            try testing.testingSqliteStore(&storage, &tmp, std.testing.io);
            storage_open = true;
            try std.testing.expect(try storage.recoverOneUncertainAction(.empty()));
        }
        if (case == .empty_allocation or case == .oversized_allocation) {
            try std.testing.expect(!failing.has_induced_failure);
            try std.testing.expect(parts.lifecycle.launchAllowed());
            const text = if (case == .empty_allocation) "Image read failed: TruncatedImage." else "Image read failed: ImageResourceLimit.";
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='failed' AND c.form=0 AND c.byte_length=?2 AND c.digest=?3", .{ selected.action_id, text.len, testing.Blob{ .bytes = &protocol.contentDigest(text) } }));
        }
        if (case == .result_allocation) try std.testing.expect(failing.has_induced_failure);
        if (case == .payload_capacity or case == .index_capacity) {
            try std.testing.expect(parts.lifecycle.launchAllowed());
            try std.testing.expect(!storage.isFenced());
            const text = result_fault.storage_failed_text;
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='storage_failed' AND c.form=0 AND c.byte_length=?2 AND c.digest=?3", .{ selected.action_id, text.len, testing.Blob{ .bytes = &protocol.contentDigest(text) } }));
            try std.testing.expect(!(try storage.recoverOneUncertainAction(.empty())));
        }
        const code = switch (case) {
            .snapshot, .background => "succeeded",
            .stop, .stop_between_ticks => "cancelled",
            .payload_capacity, .index_capacity => "storage_failed",
            .result_allocation, .capture, .seal, .publication, .shutdown => "indeterminate",
            else => "failed",
        };
        try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2 AND attempt_ordinal=1", .{ selected.action_id, code }));
        if (case == .snapshot or case == .background) {
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM content WHERE digest=?1 AND byte_length=?2", .{ testing.Blob{ .bytes = &protocol.contentDigest(png) }, png.len }));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation action JOIN content result ON result.content_id=action.resolution_content_id WHERE action.action_id=?1 AND result.form=1", .{selected.action_id}));
        }
        // A resolved or recovered Action is never selected again, even when
        // its original pathname is gone or now names different bytes.
        try std.testing.expect(try storage.nextAction(.read_image, .{ .free_credit = .one, .mcp_open = true }) == null);
    }
}
