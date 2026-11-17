const std = @import("std");
const execution = @import("execution.zig");
const Host = @import("server_host.zig").Host;
const store = @import("store.zig");
const InputCapture = @import("InputCapture.zig");
const arguments = @import("read_image_arguments.zig");
const source_file = @import("os/read_image_file.zig");
const fenceDispatch = @import("server_host.zig").fenceDispatch;
const tool_settle = @import("tool_settle.zig");
const result_fault = @import("result_fault.zig");
const image_intake = @import("image_intake.zig");
const FileSource = @import("image_file_source.zig").FileSource;

pub const capacity = 16;

const Active = struct {
    token: execution.CustodyToken,
    profile: @import("tool_record.zig").Profile = undefined,
    preparation_failure: ?result_fault.Failure = null,
    binding: store.ActionAttemptBinding,
    source: ?std.Io.File = null,
    capture: ?InputCapture = null,
    input: store.ActionExecutionInput = undefined,
    path: arguments.Path = .{},
    length: u64 = 0,
    deadline: std.Io.Clock.Timestamp = undefined,
    file_source: FileSource = undefined,
    intake: image_intake.Intake = .{},

    fn recordFailure(self: *Active, failure: result_fault.Failure) anyerror {
        self.preparation_failure = failure;
        return switch (failure) {
            inline else => |err| err,
        };
    }

    fn slot(self: *const Active, phase: []const u8) tool_settle.Slot {
        return .{ .token = self.token, .binding = self.binding, .publication_phase = phase };
    }

    fn destroy(self: *Active, host: *Host) void {
        const token = self.token;
        if (self.source) |source| source.close(host.io);
        if (self.capture) |*capture| capture.close();
        host.allocator.destroy(self);
        host.custody.detach(token) catch unreachable;
        host.custody.cleanupComplete(token) catch unreachable;
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
            if (active.binding.action_id == action) return true;
        };
        return false;
    }

    pub noinline fn admit(self: *Calls, host: *Host, call: store.ReadyAction) @import("execution_turn.zig").Admission {
        const entry = for (&self.entries) |*entry| {
            if (entry.* == null) break entry;
        } else return .retry_later;
        const token = host.custody.reserve() orelse return .retry_later;
        const active = host.allocator.create(Active) catch {
            host.custody.releaseUnused(token) catch unreachable;
            return .retry_later;
        };
        active.* = .{ .token = token, .binding = undefined };
        var admission = (host.store.admitActionAttempt(call, 300_000, host.hooks.storeFaults(.attempt_admission)) catch |err| {
            host.allocator.destroy(active);
            host.custody.releaseUnused(token) catch unreachable;
            fenceDispatch(host, "image read admission", err);
            return .retry_later;
        }) orelse {
            host.allocator.destroy(active);
            host.custody.releaseUnused(token) catch unreachable;
            return .admitted;
        };
        active.binding = host.custody.attach(token, &admission.permit) catch |err| {
            host.allocator.destroy(active);
            host.custody.releaseUnused(token) catch unreachable;
            fenceDispatch(host, "image read custody", err);
            return .admitted;
        };
        prepare(host, active) catch |err| {
            fail(host, active, active.preparation_failure orelse .{ .source = err });
            active.destroy(host);
            return .admitted;
        };
        entry.* = active;
        return .admitted;
    }

    pub fn service(self: *Calls, host: *Host) bool {
        var progress = false;
        for (&self.entries) |*entry| if (entry.*) |active| {
            const stopped = host.store.actionSupersededByStop(active.binding) catch |err| {
                fenceDispatch(host, "image read stop", err);
                return progress;
            };
            if (stopped != null) {
                settleText(host, active, .cancelled, "Stopped before this image read completed.");
            } else if (std.Io.Clock.Timestamp.now(host.io, .awake).raw.nanoseconds >= active.deadline.raw.nanoseconds) {
                settleText(host, active, .timed_out, "Image read timed out before its result was saved.");
            } else {
                const progress_result = active.intake.step();
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
                    .ready => unreachable,
                }
                publish(host, active);
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
    const loan = active.capture.?.seal() catch |err| {
        _ = tool_settle.fence(host, "image snapshot sealing", .{ .capture = err });
        return;
    };
    _ = tool_settle.result(host, active.slot("image read result publication"), active.profile, .succeeded, .{ .parts = loan });
}

fn settleText(host: *Host, active: *Active, code: store.ActionResolutionCode, text: []const u8) void {
    _ = tool_settle.fixed(host, active.slot("image read failure publication"), code, text);
}

fn fail(host: *Host, active: *Active, fault: result_fault.Failure) void {
    const err = switch (fault) {
        inline else => |value| value,
    };
    if (host.store.isFenced()) {
        fenceDispatch(host, "image read canonical input", err);
    } else if (err == error.HostDispatchSuppressed) {
        return;
    } else if (err == error.SupersededByControl) {
        settleText(host, active, .cancelled, "Stopped before this image read completed.");
    } else {
        if (result_fault.classify(fault) == .storage_full) {
            _ = tool_settle.failure(host, active.slot("image read failure publication"), "image snapshot capture", fault);
        } else {
            _ = tool_settle.message(host, active.slot("image read failure publication"), .failed, "Image read failed: {s}.", .{@errorName(err)});
        }
    }
}

fn failInput(host: *Host, active: *Active, fault: result_fault.Failure) void {
    if (host.store.isFenced()) {
        _ = tool_settle.fence(host, "image read canonical input", fault);
        return;
    }
    switch (result_fault.classify(fault)) {
        .rejected => {
            const err = switch (fault) {
                inline else => |value| value,
            };
            _ = tool_settle.message(host, active.slot("image read failure publication"), .failed, "Image read failed: {s}.", .{@errorName(err)});
        },
        .storage_full, .suppressed, .uncertain => _ = tool_settle.failure(host, active.slot("image read failure publication"), "image snapshot capture", fault),
        .superseded => settleText(host, active, .cancelled, "Stopped before this image read completed."),
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

noinline fn prepare(host: *Host, active: *Active) !void {
    host.store.readActionExecutionInput(.read_image, active.binding, &active.input) catch |err| return active.recordFailure(.{ .store = err });
    active.profile = @import("tool_record.zig").Runner.read_image.resultProfile(false);
    var reader: store.ContentReader = undefined;
    reader.open(host.store.openContent(active.input.arguments) catch |err| return active.recordFailure(.{ .store = err }));
    defer reader.close();
    var source: Source = .{ .reader = &reader, .length = active.input.arguments.length };
    if (!(arguments.parse(&source, &active.path) catch |err| return active.recordFailure(.{ .store = err }))) return active.recordFailure(.{ .source = error.InvalidImageArguments });
    const now = std.Io.Clock.Timestamp.now(host.io, .awake);
    active.deadline = now.addDuration(.{ .raw = .fromMilliseconds(@intCast(active.input.timeout_ms)), .clock = .awake });
    host.custody.consumeLaunchAuthority(active.token, .{ .action = active.binding }, now) catch |err| return active.recordFailure(.{ .store = err });
    host.store.withActionLaunchHandoff(active.binding, .{ .host = host, .active = active }, struct {
        fn handoff(context: anytype, cutoff: u64) !void {
            try context.host.withEffectLaunch(context, launch);
            try context.host.custody.watchMessages(context.active.token, cutoff);
        }
        fn launch(context: anytype) !void {
            context.active.source = source_file.open(context.host.io, context.active.input.runner.read_image.workspace.slice(), context.active.path.slice()) catch |err| return context.active.recordFailure(.{ .source = err });
        }
    }.handoff) catch |err| return if (active.preparation_failure != null) err else active.recordFailure(.{ .store = err });
    active.length = (active.source.?.stat(host.io) catch |err| return active.recordFailure(.{ .source = err })).size;
    // Validate size before allocating scratch or reading payload bytes.
    active.file_source = .{ .io = host.io, .file = active.source.?, .length = active.length };
    switch (active.intake.begin(active.file_source.source(), .{})) {
        .failed => |fault| return active.recordFailure(fault),
        .ready => {},
        else => unreachable,
    }
    active.capture = .{ .io = host.io, .resources = null };
    @import("server_input_scratch.zig").init(host, active.binding.action_id, &active.capture.?) catch |err| return active.recordFailure(.{ .capture = err });
    switch (active.intake.attach(&active.capture.?)) {
        .failed => |fault| return active.recordFailure(fault),
        .pending => {},
        else => unreachable,
    }
}

const TestCase = enum { snapshot, missing, invalid, oversized, stop, stop_between_ticks, background, source_io, capture, seal, publication, shutdown, payload_capacity, index_capacity };

test "read_image custody owns snapshot publication stop background and recovery" {
    try testReadImage(&.{ .snapshot, .missing, .invalid, .oversized, .stop, .background, .source_io, .capture, .seal, .publication, .shutdown });
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
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "image.png", .data = if (case == .invalid) "not an image" else if (case == .payload_capacity or case == .stop_between_ticks) multi_png else png });
            if (case == .oversized) {
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
        var host: Host = .{ .io = std.testing.io, .allocator = std.testing.allocator, .lease = undefined, .store = &storage, .retention = &queue, .custody = execution.CustodyPool.initialize(&records) };
        var capture_vtable = std.testing.io.vtable.*;
        var calls: Calls = .{};
        defer calls.shutdown(&host);
        try std.testing.expectEqual(@import("execution_turn.zig").Admission.admitted, calls.admit(&host, selected));
        if (case == .missing or case == .oversized) {
            try std.testing.expect(!calls.any());
        } else {
            const active = calls.entries[0].?;
            try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
            try std.testing.expect(calls.contains(selected.action_id));
            try std.testing.expectError(error.DispatchPermitConsumed, host.custody.consumeLaunchAuthority(active.token, .{ .action = active.binding }, .now(std.testing.io, .awake)));
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
                active.capture.?.io.vtable = &capture_vtable;
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
            if (case == .publication) host.hooks.failures.insert(.result_before_commit);
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
                const outcome = active.intake.step();
                try std.testing.expect(outcome == .failed);
                try std.testing.expect(outcome.failed == .source);
                failInput(&host, active, outcome.failed);
                active.destroy(&host);
                calls.entries[0] = null;
                try std.testing.expect(host.launchAllowed());
            } else if (case == .seal) {
                const complete = active.intake.step();
                try std.testing.expect(complete == .kept);
                try active.capture.?.resources.?.index.setLength(std.testing.io, 0);
                publish(&host, active);
                calls.shutdown(&host);
            } else if (case == .shutdown) {
                _ = host.advance(.stopping);
                calls.shutdown(&host);
            } else try std.testing.expect(calls.service(&host));
        }
        try std.testing.expect(!calls.any());
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
        try std.testing.expectEqual(baseline, used.load(.acquire));
        if (case == .capture or case == .seal or case == .publication or case == .shutdown) {
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL", .{selected.action_id}));
            if (case != .shutdown) try std.testing.expect(!host.launchAllowed());
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
        if (case == .payload_capacity or case == .index_capacity) {
            try std.testing.expect(host.launchAllowed());
            try std.testing.expect(!storage.isFenced());
            const text = result_fault.storage_failed_text;
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(&storage, "SELECT count(*) FROM action_operation a JOIN content c ON c.content_id=a.resolution_content_id WHERE a.action_id=?1 AND a.resolution_code='storage_failed' AND c.form=0 AND c.byte_length=?2 AND c.digest=?3", .{ selected.action_id, text.len, testing.Blob{ .bytes = &protocol.contentDigest(text) } }));
            try std.testing.expect(!(try storage.recoverOneUncertainAction(.empty())));
        }
        const code = switch (case) {
            .snapshot, .background => "succeeded",
            .stop, .stop_between_ticks => "cancelled",
            .payload_capacity, .index_capacity => "storage_failed",
            .capture, .seal, .publication, .shutdown => "indeterminate",
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
