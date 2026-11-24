const std = @import("std");
const execution = @import("execution.zig");
const Host = @import("server_host.zig").Host;
const store = @import("store.zig");
const protocol = @import("protocol.zig");
const Running = @import("mcp/Running.zig");
const offered = @import("mcp/offered.zig");
const action_attempt = @import("action_attempt.zig");
const result_fault = @import("result_fault.zig");

pub const Server = @import("mcp/servers.zig").Server;
pub const Servers = @import("mcp/servers.zig").Servers;

pub const capacity = 16;

const labels: action_attempt.Labels = .{
    .admission = "MCP admission",
    .custody = "MCP custody attachment",
    .stop = "MCP stop reconciliation",
    .result = "MCP settlement",
    .failure = "MCP settlement",
};

pub const Active = struct {
    attempt: action_attempt.Attempt = undefined,
    arena: std.heap.ArenaAllocator,
    running: Running = undefined,
    started: bool = false,
    profile: @import("tool_record.zig").Profile = undefined,

    fn freeLocal(self: *Active, allocator: std.mem.Allocator) void {
        if (self.started) self.running.deinit();
        self.arena.deinit();
        allocator.destroy(self);
    }

    fn destroy(self: *Active, host: *Host) void {
        const closing = self.attempt.close();
        self.freeLocal(host.allocator);
        closing.finish();
    }
};

pub const Calls = struct {
    entries: [capacity]?*Active = @splat(null),

    pub fn any(self: *const Calls) bool {
        for (self.entries) |entry| if (entry != null) return true;
        return false;
    }

    pub fn full(self: *const Calls) bool {
        for (self.entries) |entry| if (entry == null) return false;
        return true;
    }

    pub fn contains(self: *const Calls, action_id: u64) bool {
        for (self.entries) |entry| if (entry) |active| {
            if (active.attempt.binding.action_id == action_id) return true;
        };
        return false;
    }

    pub noinline fn admit(self: *Calls, host: *Host, parts: action_attempt.Parts, call: store.ReadyAction) @import("execution_turn.zig").Admission {
        var place: ?*?*Active = null;
        for (&self.entries) |*entry| if (entry.* == null) {
            place = entry;
            break;
        };
        const entry = place orelse return .retry_later;
        const active = host.allocator.create(Active) catch return .retry_later;
        active.* = .{ .arena = .init(host.allocator) };
        const timeout_ms = for (host.mcp_servers.entries) |*server| {
            if (std.mem.eql(u8, server.name, call.server.slice())) break server.timeout_ms;
        } else @import("mcp/servers.zig").default_timeout_ms;
        active.attempt = switch (action_attempt.admit(parts, call, timeout_ms, labels)) {
            .attempt => |attempt| attempt,
            .busy, .refused => {
                active.freeLocal(host.allocator);
                return .retry_later;
            },
            .none, .unattached => {
                active.freeLocal(host.allocator);
                return .admitted;
            },
        };
        prepare(host, active) catch |err| {
            preparationFailed(host, active, err);
            active.destroy(host);
            return .admitted;
        };
        if (!active.started) {
            active.destroy(host);
            return .admitted;
        }
        entry.* = active;
        return .admitted;
    }

    pub fn service(self: *Calls, host: *Host) bool {
        var progress = false;
        for (&self.entries) |*entry| if (entry.*) |active| {
            switch (active.attempt.stopped()) {
                .fenced => return progress,
                .stopped => {
                    cancel(active);
                    active.destroy(host);
                    entry.* = null;
                    progress = true;
                    continue;
                },
                .running => {},
            }
            const now = nowMs(host);
            const fd = active.running.fd();
            if (fd >= 0 and now < active.running.deadlineMs()) {
                var poll: std.c.pollfd = .{ .fd = fd, .events = active.running.events(), .revents = 0 };
                const ready = std.c.poll(@ptrCast(&poll), 1, 0);
                if (ready == 0) continue;
            }
            var ended: ?@import("mcp/result_text.zig").Ended = null;
            if (!active.running.requestSent()) {
                active.attempt.dispatch(.{ .active = active, .now = now, .ended = &ended }, struct {
                    fn send(context: anytype) !void {
                        context.ended.* = context.active.running.poll(context.now);
                    }
                }.send) catch |err| {
                    switch (err) {
                        error.SupersededByControl => cancel(active),
                        error.HostDispatchSuppressed => {},
                        else => _ = active.attempt.settle(.{ .fence = .{ .phase = "MCP dispatch", .fault = .{ .store = err } } }),
                    }
                    active.destroy(host);
                    entry.* = null;
                    progress = true;
                    continue;
                };
            } else {
                ended = active.running.poll(now);
            }
            if (ended) |finished| {
                complete(host, active, finished);
                active.destroy(host);
                entry.* = null;
                progress = true;
            }
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

/// Owns the replay cursor while intake scans and copies the borrowed MCP data.
const ImageDecoder = struct {
    encoded: []const u8 = "",
    decoder: @import("mcp/result_parts.zig").Decoder = undefined,

    pub fn source(self: *ImageDecoder, image: @import("mcp/result_parts.zig").Image) error{ UnsupportedMimeType, InvalidBase64 }!@import("image_intake.zig").Source {
        const format: @import("input_media.zig").Format = if (@import("mcp/document.zig").keyIs(image.mime, "image/png")) .png else if (@import("mcp/document.zig").keyIs(image.mime, "image/jpeg")) .jpeg else return error.UnsupportedMimeType;
        self.encoded = image.data;
        self.decoder = @import("mcp/result_parts.zig").Decoder.init(image.data);
        var window: [2048]u8 = undefined;
        var length: u64 = 0;
        while (true) {
            const bytes = try self.decoder.next(&window);
            if (bytes.len == 0) break;
            length += bytes.len;
        }
        self.decoder = @import("mcp/result_parts.zig").Decoder.init(image.data);
        return .{ .length = length, .format = format, .context = self, .next = next, .rewind = rewind };
    }

    fn next(context: *anyopaque, window: []u8) anyerror!usize {
        const self: *ImageDecoder = @ptrCast(@alignCast(context));
        return (try self.decoder.next(window)).len;
    }

    fn rewind(context: *anyopaque) anyerror!void {
        const self: *ImageDecoder = @ptrCast(@alignCast(context));
        self.decoder = @import("mcp/result_parts.zig").Decoder.init(self.encoded);
    }
};

const Rendered = union(enum) { code: @import("mcp/result_text.zig").Code, failed: @import("result_fault.zig").Failure };

/// The ending and decoder borrow Running's answer until this function returns.
fn renderResult(result: *@import("tool_result.zig").Result, ended: @import("mcp/result_text.zig").Ended) Rendered {
    var sink: ResultSink = .{ .out = result.text(), .result = result };
    const code = @import("mcp/result_text.zig").render(&sink, ended) catch |err| return .{ .failed = sink.failure orelse .{ .capture = err } };
    return .{ .code = code };
}

const ResultSink = struct {
    out: *std.Io.Writer,
    result: *@import("tool_result.zig").Result,
    failure: ?@import("result_fault.zig").Failure = null,

    fn diagnostic(self: *ResultSink, reason: []const u8) !void {
        try @import("image_intake.zig").writeInPlace(self.out, reason);
    }

    pub fn badImage(self: *ResultSink, reason: []const u8, _: []const u8) !void {
        try self.diagnostic(reason);
    }

    pub fn image(self: *ResultSink, image_block: @import("mcp/result_parts.zig").Image, _: []const u8, last: bool) !void {
        var decoder: ImageDecoder = .{};
        const source = decoder.source(image_block) catch |err| return self.diagnostic(switch (err) {
            error.UnsupportedMimeType => "unsupported MIME type",
            error.InvalidBase64 => "invalid base64",
        });
        var progress = self.result.beginImage(source, last);
        while (true) switch (progress) {
            .pending => progress = self.result.stepImage(),
            .kept => return,
            .rejected => |rejection| return self.diagnostic(switch (rejection) {
                .reason => |reason| reason,
                .failure => |failure| switch (failure) {
                    inline else => |err| @errorName(err),
                },
            }),
            .failed => |failure| {
                self.failure = failure;
                return error.ResultFailure;
            },
        };
    }
};

/// Complete while Running still owns the response and any borrowed bytes.
noinline fn complete(host: *Host, active: *Active, ended: @import("mcp/result_text.zig").Ended) void {
    const result = @import("tool_result.zig").Result.create(host, active.attempt.binding.action_id, active.profile) catch |err| {
        _ = active.attempt.settle(.{ .fence = .{ .phase = "MCP result creation", .fault = .{ .capture = err } } });
        return;
    };
    defer result.destroy();
    const rendered = renderResult(result, ended);
    const code = switch (rendered) {
        .failed => |failure| {
            settleFailure(active, failure, false);
            return;
        },
        .code => |code| code,
    };
    const resolution: store.ActionResolutionCode = switch (code) {
        .succeeded => .succeeded,
        .failed => .failed,
        .spawn_failed => .spawn_failed,
        .indeterminate => .indeterminate,
        .cancelled => .cancelled,
    };
    const finished = result.finish();
    switch (finished) {
        .failed => |failed| settleFailure(active, failed.failure, failed.seal),
        .value => |value| _ = active.attempt.settle(.{ .result = .{ .code = resolution, .value = value, .retained = result } }),
    }
}

fn settleFailure(active: *Active, failure: result_fault.Failure, seal: bool) void {
    if (seal) {
        _ = active.attempt.settle(.{ .fence = .{ .phase = "MCP image sealing", .fault = failure } });
    } else if (result_fault.classify(failure) == .storage_full) {
        _ = active.attempt.settle(.{ .failure = .{ .fault = failure, .phase = "MCP result capture" } });
    } else {
        _ = active.attempt.settle(.{ .fence = .{ .phase = "MCP result capture", .fault = failure } });
    }
}

fn nowMs(host: *const Host) u64 {
    return @intCast(@divTrunc(std.Io.Clock.Timestamp.now(host.io, .awake).raw.nanoseconds, std.time.ns_per_ms));
}

fn settle(active: *Active, code: store.ActionResolutionCode, text: []const u8) void {
    _ = active.attempt.settle(.{ .text = .{ .code = code, .text = text } });
}

fn preparationFailed(host: *Host, active: *Active, err: anyerror) void {
    if (host.store.isFenced()) {
        _ = active.attempt.settle(.{ .fence = .{ .phase = "MCP input", .fault = .{ .store = err } } });
    } else if (err == error.SupersededByControl) {
        cancel(active);
    } else {
        settle(active, .spawn_failed, "Failed, not run: the Host could not prepare this MCP call.");
    }
}

noinline fn prepare(host: *Host, active: *Active) !void {
    const arena = active.arena.allocator();
    const input = try arena.create(store.ActionExecutionInput);
    try host.store.readActionExecutionInput(.mcp, active.attempt.binding, input);
    active.profile = @import("tool_record.zig").Runner.mcp.resultProfile(input.runner.mcp.bash_offered);
    const config = for (host.mcp_servers.entries) |*server| {
        if (std.mem.eql(u8, server.name, input.runner.mcp.server.slice())) break server;
    } else {
        const text = try std.fmt.allocPrint(arena, "Failed, not run: MCP server {s} is not available (mcp_server_unavailable).", .{input.runner.mcp.server.slice()});
        settle(active, .spawn_failed, text);
        return;
    };
    const arguments = try readContent(host, arena, input.arguments);
    var turn: std.Io.Writer.Allocating = .init(arena);
    try protocol.writeShape(&turn.writer, .{protocol.Hole.decimal}, .{active.attempt.binding.turn_id});
    const start: Running.Input = .{
        .server = .{ .target = config.target, .bearer_token = config.token },
        .client = offered.client,
        .name = @import("tools.zig").remoteNameOf(input.runner.mcp.name.slice(), input.runner.mcp.remote_name.slice()),
        .input_schema = try readContent(host, arena, input.runner.mcp.input_schema),
        .arguments = arguments,
        .caller = .{
            .session_id = input.session.slice(),
            .parent_session_id = if (input.runner.mcp.parent) |*parent| parent.slice() else null,
            .root_session_id = input.runner.mcp.root.slice(),
            .turn_id = turn.written(),
        },
        .id = 1,
        .server_name = config.name,
        .timeout_ms = input.timeout_ms,
    };
    switch (active.attempt.launch(.channel, std.Io.Clock.Timestamp.now(host.io, .awake), .{ .host = host, .active = active, .input = start }, begin)) {
        .started => {},
        .authority, .handoff => |err| return err,
    }
}

fn begin(context: anytype) !void {
    try context.active.running.start(context.host.allocator, context.input, nowMs(context.host));
    context.active.started = true;
}

fn readContent(host: *Host, allocator: std.mem.Allocator, reference: store.ContentReference) ![]const u8 {
    const bytes = try allocator.alloc(u8, std.math.cast(usize, reference.length) orelse return error.OutOfMemory);
    var reader: store.ContentReader = undefined;
    reader.open(try host.store.openContent(reference));
    defer reader.close();
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(bytes.len, offset + store.ContentReader.content_window_bytes);
        const count = try reader.read(offset, bytes[offset..end]);
        if (count == 0) return error.ShortCanonicalRead;
        offset += count;
    }
    return bytes;
}

fn cancel(active: *Active) void {
    const sent = active.started and active.running.requestSent();
    const text = @import("mcp/action_text.zig");
    settle(active, if (sent) .indeterminate else .cancelled, if (sent) text.stop_unknown else text.stop_not_sent);
}

const TestParts = if (@import("builtin").is_test) @import("server_host_testing.zig").TestParts else void;

test "MCP Host call bound refuses admission before touching the Store" {
    var active: Active = .{ .attempt = .{ .parts = undefined, .token = undefined, .labels = undefined, .binding = .{ .action_id = 1, .parent_operation_id = 1, .turn_id = 1 } }, .arena = .init(std.testing.allocator) };
    defer active.arena.deinit();
    var calls: Calls = .{ .entries = @splat(&active) };
    try std.testing.expect(calls.full());
    try std.testing.expectEqual(@import("execution_turn.zig").Admission.retry_later, calls.admit(undefined, undefined, .{ .action_id = 17, .runner = .mcp, .server = .{} }));
    calls.entries[0] = null;
    try std.testing.expect(!calls.full());
}

test "MCP full output hints follow the frozen Bash offer despite later settings" {
    const store_testing = store.testing;
    const tools = @import("tools.zig");
    const wire_request = @import("wire_request.zig");
    const output_retention = @import("output_retention.zig");
    const Script = @import("mcp/test_server.zig");
    const poll = @import("test_poll");
    const gpa = std.testing.allocator;
    const records = comptime store_testing.hostToolRecordsWith(&.{.{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page.", .input_schema = "{\"type\":\"object\"}" }});
    var digests: [records.len][32]u8 = undefined;
    for (&records, &digests) |*record, *digest| digest.* = tools.recordDigest(record);
    const host_tool_set: tools.HostToolSet = .{ .records = &records, .digests = &digests };
    const payload = try gpa.alloc(u8, @import("mcp/result_text.zig").excerpt_bytes + 1);
    defer gpa.free(payload);
    @memset(payload, 'x');
    const body = try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{payload});
    defer gpa.free(body);
    const reply = try std.fmt.allocPrint(gpa, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer gpa.free(reply);
    for ([_]bool{ false, true }) |bash_offered| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: store.Store = undefined;
        try store_testing.testingStoreWith(&.{ .engine = .sqlite }, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
        defer storage.close() catch unreachable;
        var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
        const workspace = try store.testingCanonicalCwd(std.testing.io, &workspace_buffer);
        var configure = try store_testing.completeConfiguration("mcp-output-configure", "", workspace, "model-a");
        configure.configuration.tools = try .of(if (bash_offered) &.{ "bash", "fetch_page" } else &.{"fetch_page"});
        configure.configuration.permission_mode.state = .value;
        try configure.configuration.permission_mode.value.set("bypass");
        const session = (try storage.configure(&configure, .{})).accepted.session;
        try store_testing.submitTestMessage(&storage, &tmp, "task", "mcp-output-task", session.slice(), "fetch");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        var update: wire_request.ConfigureCommand = .{ .session = session };
        try update.key.set("mcp-output-live-tools");
        update.configuration.tools = try .of(if (bash_offered) &.{"fetch_page"} else &.{ "bash", "fetch_page" });
        try std.testing.expect(try storage.configure(&update, .{}) == .accepted);
        try store.settleCallsForTesting(&storage, &tmp, model, "mcp-output-calls", &.{.{ .item_id = "item", .name = "fetch_page", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }});
        const selected = (try storage.nextAction(.mcp, .{ .free_credit = .one, .mcp_open = true })).?;
        var script: Script = .{ .reply = reply };
        try script.start();
        defer script.stop();
        var url_buffer: [128]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/mcp", .{script.port});
        var server_name = "docs".*;
        var token = "t".*;
        var configs = [_]Server{.{ .name = &server_name, .url = url, .token = &token, .target = try @import("http1/request.zig").parseTarget(url), .timeout_ms = 10_000 }};
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var used: std.atomic.Value(u64) = .init(0);
        var entries: [2]output_retention.Entry = @splat(.{});
        var retention = output_retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = Running.max_answer_bytes }, &entries);
        defer retention.cleanupAll();
        var custody_records: [2]execution.CustodyRecord = @splat(.{});
        var host: Host = .{ .custody = execution.CustodyPool.initialize(&custody_records), .io = std.testing.io, .allocator = gpa, .lease = undefined, .store = &storage, .mcp_servers = .{ .entries = &configs }, .retention = &retention };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, undefined);
        var calls: Calls = .{};
        defer calls.shutdown(&host);
        try std.testing.expectEqual(@import("execution_turn.zig").Admission.admitted, calls.admit(&host, .{ .store = &storage, .lifecycle = host.lifecycle, .probes = host.probes, .custody = &host.custody }, selected));
        const Drive = struct {
            calls: *Calls,
            host: *Host,
            fn step(self: *@This()) !bool {
                _ = self.calls.service(self.host);
                return !self.calls.any();
            }
        };
        var drive: Drive = .{ .calls = &calls, .host = &host };
        try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(10)), &drive, Drive.step);
        try std.testing.expect(script.request_received.load(.acquire));
        try std.testing.expect(!storage.isFenced());
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
        const recycled = host.custody.reserve().?;
        try host.custody.releaseUnused(recycled);
        const report = try store.testingSessionReportWithProfile(&storage, &tmp, session.slice(), 128 * 1024, .full);
        defer gpa.free(report);
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, report, .{});
        defer parsed.deinit();
        const result = parsed.value.object.get("full").?.object.get("actions").?.array.items[0].object.get("result").?.object.get("text").?.string;
        const expected = if (bash_offered)
            try std.fmt.allocPrint(gpa, "{s}\n[1 more bytes not shown]\nFull output: {s}/mcp-output-{d}-1.tmp\n", .{ payload[0 .. payload.len - 1], root, selected.action_id })
        else
            try std.fmt.allocPrint(gpa, "{s}\n[1 more bytes not shown]", .{payload[0 .. payload.len - 1]});
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, result);
        try std.testing.expectEqual(@as(usize, @intFromBool(bash_offered)), retention.occupied());
    }
}

test "MCP call of a prefixed tool sends the name its server listed" {
    const store_testing = store.testing;
    const tools = @import("tools.zig");
    const output_retention = @import("output_retention.zig");
    const Script = @import("mcp/test_server.zig");
    const poll = @import("test_poll");
    const gpa = std.testing.allocator;
    const records = comptime store_testing.hostToolRecordsWith(&.{.{ .name = "docs__fetch_page", .remote_name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page.", .input_schema = "{\"type\":\"object\"}" }});
    var digests: [records.len][32]u8 = undefined;
    for (&records, &digests) |*record, *digest| digest.* = tools.recordDigest(record);
    const host_tool_set: tools.HostToolSet = .{ .records = &records, .digests = &digests };
    const reply = Script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"ok\"}]}}");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var storage: store.Store = undefined;
    try store_testing.testingStoreWith(&.{ .engine = .sqlite }, &storage, &tmp, std.testing.io, .{ .host_tool_set = &host_tool_set });
    defer storage.close() catch unreachable;
    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    const workspace = try store.testingCanonicalCwd(std.testing.io, &workspace_buffer);
    var configure = try store_testing.completeConfiguration("mcp-prefix-configure", "", workspace, "model-a");
    configure.configuration.tools = try .of(&.{"docs__fetch_page"});
    configure.configuration.permission_mode.state = .value;
    try configure.configuration.permission_mode.value.set("bypass");
    const session = (try storage.configure(&configure, .{})).accepted.session;
    try store_testing.submitTestMessage(&storage, &tmp, "task", "mcp-prefix-task", session.slice(), "fetch");
    const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
    try store.settleCallsForTesting(&storage, &tmp, model, "mcp-prefix-calls", &.{.{ .item_id = "item", .name = "docs__fetch_page", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }});
    const selected = (try storage.nextAction(.mcp, .{ .free_credit = .one, .mcp_open = true })).?;
    var script: Script = .{ .reply = reply };
    try script.start();
    defer script.stop();
    var url_buffer: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/mcp", .{script.port});
    var server_name = "docs".*;
    var token = "t".*;
    var configs = [_]Server{.{ .name = &server_name, .url = url, .token = &token, .target = try @import("http1/request.zig").parseTarget(url), .timeout_ms = 10_000 }};
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [2]output_retention.Entry = @splat(.{});
    var retention = output_retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = Running.max_answer_bytes }, &entries);
    defer retention.cleanupAll();
    var custody_records: [2]execution.CustodyRecord = @splat(.{});
    var host: Host = .{ .custody = execution.CustodyPool.initialize(&custody_records), .io = std.testing.io, .allocator = gpa, .lease = undefined, .store = &storage, .mcp_servers = .{ .entries = &configs }, .retention = &retention };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    var calls: Calls = .{};
    defer calls.shutdown(&host);
    try std.testing.expectEqual(@import("execution_turn.zig").Admission.admitted, calls.admit(&host, .{ .store = &storage, .lifecycle = host.lifecycle, .probes = host.probes, .custody = &host.custody }, selected));
    const Drive = struct {
        calls: *Calls,
        host: *Host,
        fn step(self: *@This()) !bool {
            _ = self.calls.service(self.host);
            return !self.calls.any();
        }
    };
    var drive: Drive = .{ .calls = &calls, .host = &host };
    try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(10)), &drive, Drive.step);
    try std.testing.expect(script.request_received.load(.acquire));
    const sent = script.seen[0..script.seen_len];
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"name\":\"fetch_page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "docs__fetch_page") == null);
}

test "MCP ordinary custody covers preparation failure init failure stop shutdown and settlement failure" {
    const store_testing = store.testing;
    const tools = @import("tools.zig");
    const output_retention = @import("output_retention.zig");
    const Case = enum { capacity_zero, capacity_occupied, capacity_detached, allocation, preparation, unavailable, init_failed, stop, stop_preparation, shutdown, settlement };
    const records = comptime store_testing.hostToolRecordsWith(&.{.{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch.", .input_schema = "{\"type\":\"object\"}" }});
    var digests: [records.len][32]u8 = undefined;
    for (&records, &digests) |*record, *digest| digest.* = tools.recordDigest(record);
    const tool_set: tools.HostToolSet = .{ .records = &records, .digests = &digests };
    for (std.enums.values(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var storage: store.Store = undefined;
        try store_testing.testingStoreWith(&.{ .engine = .sqlite }, &storage, &tmp, std.testing.io, .{ .host_tool_set = &tool_set });
        defer storage.close() catch unreachable;
        var path: [protocol.max_workspace_bytes]u8 = undefined;
        var configure = try store_testing.completeConfiguration("configure", "", try store.testingCanonicalCwd(std.testing.io, &path), "model-a");
        configure.configuration.tools = try .of(&.{"fetch_page"});
        configure.configuration.permission_mode.state = .value;
        try configure.configuration.permission_mode.value.set("bypass");
        const session = (try storage.configure(&configure, .{})).accepted.session;
        try store_testing.submitTestMessage(&storage, &tmp, "input", "task", session.slice(), "fetch");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        try store.settleCallsForTesting(&storage, &tmp, model, "calls", &.{.{ .item_id = "item", .name = "fetch_page", .encoded_call_id = "call", .decoded_call_id = "call", .encoded_arguments = "{}", .decoded_arguments = "{}" }});
        const selected = (try storage.nextAction(.mcp, .{ .free_credit = .one, .mcp_open = true })).?;
        var oversized_token: [40 * 1024]u8 = @splat('t');
        var name = "docs".*;
        var url = "http://127.0.0.1:1/mcp".*;
        var configs = [_]Server{.{ .name = &name, .url = &url, .token = &oversized_token, .target = try @import("http1/request.zig").parseTarget(&url), .timeout_ms = 30_000 }};
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var used: std.atomic.Value(u64) = .init(0);
        var retained: [2]output_retention.Entry = @splat(.{});
        var retention = output_retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = Running.max_answer_bytes }, &retained);
        defer retention.cleanupAll();
        var custody_records: [2]execution.CustodyRecord = @splat(.{});
        var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = if (case == .allocation) 0 else 1 });
        var host: Host = .{ .custody = execution.CustodyPool.initialize(&custody_records), .io = std.testing.io, .allocator = if (case == .allocation or case == .preparation) failing.allocator() else std.testing.allocator, .lease = undefined, .store = &storage, .mcp_servers = .{ .entries = if (case == .unavailable) &.{} else &configs }, .retention = &retention };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, undefined);
        const parts: action_attempt.Parts = .{ .store = &storage, .lifecycle = host.lifecycle, .probes = host.probes, .custody = &host.custody };
        if (case == .capacity_zero or case == .capacity_occupied or case == .capacity_detached) {
            if (case == .capacity_zero) host.custody = execution.CustodyPool.initialize(&.{});
            const detached = if (case == .capacity_detached) detach: {
                host.custody = execution.CustodyPool.initialize(custody_records[0..1]);
                const token = host.custody.reserve().?;
                var permit: store.DispatchPermit = .{ .binding = .{ .turn_id = 97, .operation_id = 98, .attempt_ordinal = 1 } };
                _ = try host.custody.attach(token, &permit);
                try host.custody.detach(token);
                break :detach token;
            } else null;
            const held = if (case == .capacity_occupied) host.custody.reserve() else null;
            const other = if (case == .capacity_occupied) host.custody.reserve() else null;
            var blocked: Calls = .{};
            try std.testing.expectEqual(@import("execution_turn.zig").Admission.retry_later, blocked.admit(&host, parts, selected));
            try std.testing.expect(!blocked.any());
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT attempt_ordinal FROM action_operation WHERE action_id=?1", .{selected.action_id}));
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT authorized FROM action_operation WHERE action_id=?1", .{selected.action_id}));
            if (held) |token| try host.custody.releaseUnused(token);
            if (other) |token| try host.custody.releaseUnused(token);
            if (detached) |token| {
                try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
                try host.custody.cleanupComplete(token);
                const recycled = host.custody.reserve().?;
                try std.testing.expectError(error.StaleCustody, host.custody.cleanupComplete(token));
                try host.custody.releaseUnused(recycled);
            }
            continue;
        }
        if (case == .stop_preparation) {
            const attempt = switch (action_attempt.admit(parts, selected, 30_000, labels)) {
                .attempt => |value| value,
                else => return error.TestUnexpectedResult,
            };
            const active = try host.allocator.create(Active);
            active.* = .{ .attempt = attempt, .arena = .init(host.allocator) };
            var stop = try store.testingCompleteSessionStop("stop-preparation", session.slice());
            try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            if (prepare(&host, active)) |_| return error.TestUnexpectedResult else |err| {
                try std.testing.expectEqual(error.SupersededByControl, err);
                preparationFailed(&host, active, err);
            }
            active.destroy(&host);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='cancelled'", .{selected.action_id}));
            try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
            continue;
        }
        var calls: Calls = .{};
        defer {
            _ = host.lifecycle.advance(.stopping);
            calls.shutdown(&host);
        }
        const admitted = calls.admit(&host, parts, selected);
        if (case == .allocation) {
            try std.testing.expectEqual(@import("execution_turn.zig").Admission.retry_later, admitted);
            try std.testing.expectEqual(@as(u64, 0), try store_testing.queryU64(&storage, "SELECT attempt_ordinal FROM action_operation WHERE action_id=?1", .{selected.action_id}));
        } else {
            try std.testing.expectEqual(@import("execution_turn.zig").Admission.admitted, admitted);
            try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT attempt_ordinal FROM action_operation WHERE action_id=?1", .{selected.action_id}));
            if (case != .preparation and case != .unavailable) {
                const active = calls.entries[0].?;
                try std.testing.expectEqual(@as(usize, 1), host.custody.occupied());
                try std.testing.expectEqual(@as(std.posix.fd_t, -1), active.running.fd());
                try std.testing.expectError(error.DispatchPermitConsumed, host.custody.consumeLaunchAuthority(active.attempt.token, .{ .action = active.attempt.binding }, std.Io.Clock.Timestamp.now(host.io, .awake)));
                if (case == .shutdown) {
                    _ = host.lifecycle.advance(.stopping);
                    calls.shutdown(&host);
                } else {
                    if (case == .stop) {
                        var stop = try store.testingCompleteSessionStop("stop", session.slice());
                        try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
                    }
                    if (case == .settlement) host.probes.arm(.result_before_commit);
                    try std.testing.expect(calls.service(&host));
                }
            }
            const unresolved: u64 = @intFromBool(case == .shutdown or case == .settlement);
            try std.testing.expectEqual(unresolved, try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code IS NULL", .{selected.action_id}));
            if (case == .settlement) try std.testing.expect(!host.lifecycle.launchAllowed());
            if (case == .stop) try std.testing.expectEqual(@as(u64, 1), try store_testing.queryU64(&storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='cancelled'", .{selected.action_id}));
        }
        try std.testing.expect(!calls.any());
        try std.testing.expectEqual(@as(usize, 0), host.custody.occupied());
        const recycled = host.custody.reserve().?;
        try host.custody.releaseUnused(recycled);
    }
}
// Helpers for MCP adapter tests; keep the returned ending alive with Running.
const adapter_test_text = @import("mcp/result_text.zig");
const adapter_test_retention = @import("output_retention.zig");
const adapter_test_script = @import("mcp/test_server.zig");

fn adapterTestInput(port: u16) Running.Input {
    var target = @import("http1/request.zig").parseTarget("http://127.0.0.1:1/mcp") catch unreachable;
    target.port = port;
    return .{
        .server = .{ .target = target, .bearer_token = "t" },
        .client = .{ .name = "rui", .version = "test" },
        .name = "search",
        .input_schema = "{\"properties\":{\"q\":{}}}",
        .arguments = "{\"q\":\"x\"}",
        .caller = .{ .session_id = "s", .parent_session_id = null, .root_session_id = "s", .turn_id = "t" },
        .id = 7,
        .server_name = "test",
        .timeout_ms = 600_000,
    };
}

fn adapterTestDrive(running: *Running) !adapter_test_text.Ended {
    const Drive = struct {
        running: *Running,
        ended: ?adapter_test_text.Ended = null,
        fn step(self: *@This()) !bool {
            self.ended = self.running.poll(1);
            return self.ended != null;
        }
    };
    var context: Drive = .{ .running = running };
    const poll = @import("test_poll");
    try poll.waitUntil(std.testing.io, poll.after(std.testing.io, .fromSeconds(10)), &context, Drive.step);
    return context.ended.?;
}

test "MCP Result renders and retains text across outcomes and frozen offers" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [@import("protocol.zig").max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [4]adapter_test_retention.Entry = @splat(.{});
    var queue = adapter_test_retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = Running.max_answer_bytes }, &entries);
    defer queue.cleanupAll();
    var host: @import("server_host.zig").Host = .{ .io = std.testing.io, .allocator = gpa, .lease = undefined, .store = undefined, .retention = &queue };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    const Case = struct { length: usize, kind: enum { text, mixed_error, structured, rpc_error, refused } = .text };
    for ([_]bool{ false, true }) |bash_offered| {
        for ([_]Case{
            .{ .length = 32 },
            .{ .length = adapter_test_text.excerpt_bytes },
            .{ .length = adapter_test_text.excerpt_bytes + 128 },
            .{ .length = adapter_test_text.excerpt_bytes + 128, .kind = .mixed_error },
            .{ .length = adapter_test_text.excerpt_bytes + 128, .kind = .structured },
            .{ .length = adapter_test_text.excerpt_bytes + 128, .kind = .rpc_error },
            .{ .length = adapter_test_text.excerpt_bytes + 128, .kind = .refused },
        }) |case| {
            const payload = try gpa.alloc(u8, case.length);
            defer gpa.free(payload);
            @memset(payload, 'x');
            if (case.length > adapter_test_text.excerpt_bytes) @memcpy(payload[adapter_test_text.excerpt_bytes - 1 ..][0..2], "é");
            const body = switch (case.kind) {
                .text => try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{{\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}}]}}}}", .{payload}),
                .mixed_error => try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{{\"isError\":true,\"content\":[{{\"type\":\"text\",\"text\":\"{s}\"}},{{\"type\":\"image\",\"data\":\"x\"}}]}}}}", .{payload}),
                .structured => try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{{\"content\":[],\"structuredContent\":{{\"data\":\"{s}\"}}}}}}", .{payload}),
                .rpc_error => try std.fmt.allocPrint(gpa, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{{\"code\":-1,\"message\":\"{s}\"}}}}", .{payload}),
                .refused => try gpa.dupe(u8, payload),
            };
            defer gpa.free(body);
            const full = switch (case.kind) {
                .text, .refused => try std.fmt.allocPrint(gpa, "{s}{s}", .{ if (case.kind == .refused) "Outcome unknown: The MCP server answered HTTP 502. The call may or may not have run; it was not retried.\n" else "", payload }),
                .mixed_error => try std.fmt.allocPrint(gpa, "The tool reported an error:\n{s}\n[Image unavailable: missing image MIME type]", .{payload}),
                .structured => try std.fmt.allocPrint(gpa, "{{\"data\":\"{s}\"}}", .{payload}),
                .rpc_error => try std.fmt.allocPrint(gpa, "The MCP server returned error -1: {s}", .{payload}),
            };
            defer gpa.free(full);
            const wire = try std.fmt.allocPrint(gpa, "HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n{s}", .{ if (case.kind == .refused) "502 Bad Gateway" else "200 OK", if (case.kind == .refused) "text/plain" else "application/json", body.len, body });
            defer gpa.free(wire);
            var script: adapter_test_script = .{ .reply = wire };
            try script.start();
            defer script.stop();
            try running.start(gpa, adapterTestInput(script.port), 0);
            defer running.deinit();
            const ended = try adapterTestDrive(running);
            const result = try @import("tool_result.zig").Result.create(&host, 17, .{ .excerpt_bytes = adapter_test_text.excerpt_bytes, .retain = bash_offered });
            defer result.destroy();
            const rendered = renderResult(result, ended);
            const expected_code: adapter_test_text.Code = switch (case.kind) {
                .text, .structured => .succeeded,
                .refused => .indeterminate,
                else => .failed,
            };
            try std.testing.expect(rendered == .code);
            try std.testing.expectEqual(expected_code, rendered.code);
            const finished = result.finish();
            try std.testing.expect(finished == .value and finished.value == .text);
            const output = finished.value.text;
            result.keep();
            if (full.len <= adapter_test_text.excerpt_bytes) {
                try std.testing.expectEqualStrings(full, output);
                try std.testing.expectEqual(@as(usize, 0), queue.occupied());
                try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "mcp-output-17-1.tmp", .{}));
            } else {
                const kept = @import("utf8_validation.zig").scalarStart(full, adapter_test_text.excerpt_bytes);
                var expected: std.Io.Writer.Allocating = .init(gpa);
                defer expected.deinit();
                try expected.writer.print("{s}\n[{d} more bytes not shown]", .{ full[0..kept], full.len - kept });
                if (bash_offered) try expected.writer.print("\nFull output: {s}/mcp-output-17-1.tmp\n", .{root});
                try std.testing.expectEqualStrings(expected.written(), output);
                if (bash_offered) {
                    const saved = try tmp.dir.readFileAlloc(std.testing.io, "mcp-output-17-1.tmp", gpa, .limited(Running.max_answer_bytes));
                    defer gpa.free(saved);
                    try std.testing.expectEqualStrings(full, saved);
                    try std.testing.expectEqual(@as(u64, full.len), used.load(.acquire));
                    try std.testing.expectEqual(@as(usize, 1), queue.occupied());
                    queue.cleanupAll();
                    try std.testing.expectEqualStrings(expected.written(), output);
                } else {
                    try std.testing.expectEqual(@as(usize, 0), queue.occupied());
                    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(std.testing.io, "mcp-output-17-1.tmp", .{}));
                }
            }
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        }
    }
}

test "MCP Result reports retention refusal without changing success" {
    const gpa = std.testing.allocator;
    const payload: [adapter_test_text.excerpt_bytes + 1]u8 = @splat('x');
    const wire = adapter_test_script.jsonReply("{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"" ++ payload ++ "\"}]}}");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [@import("protocol.zig").max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    const Reason = enum { budget, capacity, reserved, sequence, create, missing };
    for (std.meta.tags(Reason)) |reason| {
        var used: std.atomic.Value(u64) = .init(0);
        var entries: [2]adapter_test_retention.Entry = @splat(.{});
        var missing_buffer: [@import("protocol.zig").max_store_bytes]u8 = undefined;
        const scratch_root = if (reason == .missing) try std.fmt.bufPrint(&missing_buffer, "{s}/missing", .{root}) else root;
        var queue = adapter_test_retention.Queue.initialize(std.testing.io, scratch_root, .{ .used = &used, .limit = if (reason == .budget) 1 else Running.max_answer_bytes }, if (reason == .capacity) &.{} else &entries);
        defer queue.cleanupAll();
        var protected_out: ?adapter_test_retention.Spill = null;
        var protected_err: ?adapter_test_retention.Spill = null;
        if (reason == .reserved) {
            protected_out = adapter_test_retention.Spill.open(&queue, "protected-out") orelse return error.TestUnexpectedResult;
            protected_err = adapter_test_retention.Spill.open(&queue, "protected-err") orelse return error.TestUnexpectedResult;
        }
        defer if (protected_out) |*spill| spill.release();
        defer if (protected_err) |*spill| spill.release();
        if (reason == .sequence) queue.next_sequence = std.math.maxInt(u64);
        if (reason == .create) try tmp.dir.createDir(std.testing.io, "mcp-output-17-1.tmp", .default_dir);
        defer if (reason == .create) tmp.dir.deleteDir(std.testing.io, "mcp-output-17-1.tmp") catch {};
        var script: adapter_test_script = .{ .reply = wire };
        try script.start();
        defer script.stop();
        var host: @import("server_host.zig").Host = .{ .io = std.testing.io, .allocator = gpa, .lease = undefined, .store = undefined, .retention = &queue };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, undefined);
        try running.start(gpa, adapterTestInput(script.port), 0);
        defer running.deinit();
        const ended = try adapterTestDrive(running);
        const result = try @import("tool_result.zig").Result.create(&host, 17, .{ .excerpt_bytes = adapter_test_text.excerpt_bytes, .retain = true });
        defer result.destroy();
        const rendered = renderResult(result, ended);
        try std.testing.expect(rendered == .code);
        try std.testing.expectEqual(adapter_test_text.Code.succeeded, rendered.code);
        const finished = result.finish();
        try std.testing.expect(finished == .value and finished.value == .text);
        try std.testing.expectEqualStrings(payload[0..adapter_test_text.excerpt_bytes] ++ "\n[1 more bytes not shown]\nFull output was not retained.\n", finished.value.text);
        result.keep();
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        try std.testing.expectEqual(@as(usize, if (reason == .reserved) 2 else 0), queue.occupied());
    }
}

test "Running oversized JSON and SSE answers preserve borrowed evidence until release" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [@import("protocol.zig").max_store_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var used: std.atomic.Value(u64) = .init(0);
    var entries: [1]adapter_test_retention.Entry = @splat(.{});
    var queue = adapter_test_retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = Running.max_answer_bytes + 1024 }, &entries);
    defer queue.cleanupAll();
    var host: @import("server_host.zig").Host = .{ .io = std.testing.io, .allocator = gpa, .lease = undefined, .store = undefined, .retention = &queue };
    var host_parts: TestParts = undefined;
    host_parts.attach(&host, undefined);
    const running = try gpa.create(Running);
    defer gpa.destroy(running);
    const response = try gpa.alloc(u8, Running.max_answer_bytes + 1024);
    defer gpa.free(response);
    const Case = struct { prefix: []const u8, code: adapter_test_text.Code, status: u16 = 200 };
    for ([_]bool{ false, true }) |sse| {
        for ([_]Case{
            .{ .prefix = "not a JSON-RPC answer: ", .code = .failed, .status = 403 },
            .{ .prefix = "not a JSON-RPC answer: ", .code = .indeterminate, .status = 502 },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":8,\"result\":{\"isError\":false,\"content\":[", .code = .failed, .status = 403 },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"input_required\",\"isError\":false,\"content\":[", .code = .indeterminate },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"isError\":false,\"content\":\"", .code = .indeterminate },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"isError\":false,\"content\":[{\"type\":\"text\",\"text\":\"", .code = .succeeded },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resultType\":\"complete\",\"isError\":true,\"content\":[{\"type\":\"text\",\"text\":\"", .code = .failed },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"", .code = .indeterminate },
            .{ .prefix = "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"bad\",\"data\":\"", .code = .failed },
        }) |case| {
            var wire: std.Io.Writer = .fixed(response);
            const body_len = Running.max_answer_bytes + 1;
            try wire.print("HTTP/1.1 {d} Test\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n\r\n", .{ case.status, if (sse) "text/event-stream" else "application/json", body_len + @as(usize, if (sse) 6 else 0) });
            if (sse) try wire.writeAll("data: ");
            try wire.writeAll(case.prefix);
            try wire.splatByteAll('x', body_len - case.prefix.len);
            var script: adapter_test_script = .{ .reply = wire.buffered() };
            try script.start();
            defer script.stop();
            try running.start(gpa, adapterTestInput(script.port), 0);
            defer running.deinit();
            const ended = try adapterTestDrive(running);
            try std.testing.expectEqual(case.code, adapter_test_text.classify(ended.ended));
            const answer = switch (ended.ended) {
                .oversized => |value| value,
                else => return error.ExpectedOversized,
            };
            try std.testing.expect(std.mem.indexOf(u8, answer.bytes, case.prefix) != null);
            try std.testing.expect(answer.bytes.len > adapter_test_text.excerpt_bytes);
            const result = try @import("tool_result.zig").Result.create(&host, 17, .{ .excerpt_bytes = adapter_test_text.excerpt_bytes, .retain = true });
            defer result.destroy();
            const rendered = renderResult(result, ended);
            try std.testing.expect(rendered == .code);
            try std.testing.expectEqual(case.code, rendered.code);
            const finished = result.finish();
            try std.testing.expect(finished == .value and finished.value == .text);
            const text = finished.value.text;
            try std.testing.expect(std.mem.indexOf(u8, text, "4194304-byte limit") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, case.prefix) != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "Full output: ") != null);
            result.keep();
            const saved = try tmp.dir.readFileAlloc(std.testing.io, "mcp-output-17-1.tmp", gpa, .limited(Running.max_answer_bytes + 1024));
            defer gpa.free(saved);
            try std.testing.expect(std.mem.endsWith(u8, saved, answer.bytes));
            try std.testing.expectEqualStrings(text[0..adapter_test_text.excerpt_bytes], saved[0..adapter_test_text.excerpt_bytes]);
            try std.testing.expectEqual(@as(u64, saved.len), used.load(.acquire));
            queue.cleanupAll();
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
            try std.testing.expectEqual(@as(std.posix.fd_t, -1), running.fd());
            try std.testing.expectEqual(null, running.poll(1));
        }
    }
}

test "MCP image part limit accounts for empty text tails" {
    const allocator = std.testing.allocator;
    const png64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";
    const image = "{\"type\":\"image\",\"data\":\"" ++ png64 ++ "\",\"mimeType\":\"image/png\"}";
    const empty = ",{\"type\":\"text\",\"text\":\"\"}";
    const part_limit = @import("input_parts.zig").max_parts;
    for ([_]struct { tail: []const u8, images: usize, text: ?[]const u8 }{
        .{ .tail = "", .images = part_limit, .text = null },
        .{ .tail = empty, .images = part_limit, .text = null },
        .{ .tail = empty ++ empty, .images = part_limit - 1, .text = "[Image unavailable: image part limit]\n" },
        .{ .tail = ",{\"type\":\"text\",\"text\":\"tail\"}", .images = part_limit - 1, .text = "[Image unavailable: image part limit]tail" },
        .{ .tail = ",{\"type\":\"image\"}", .images = part_limit - 1, .text = "[Image unavailable: image part limit][Image unavailable: missing image data]" },
    }) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [protocol.max_store_bytes]u8 = undefined;
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
        var used: std.atomic.Value(u64) = .init(0);
        var entries: [2]@import("output_retention.zig").Entry = @splat(.{});
        var queue = @import("output_retention.zig").Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 2_000_000 }, &entries);
        defer queue.cleanupAll();
        var host: Host = .{ .io = std.testing.io, .allocator = allocator, .lease = undefined, .store = undefined, .retention = &queue };
        var host_parts: TestParts = undefined;
        host_parts.attach(&host, undefined);
        var content: std.Io.Writer.Allocating = .init(allocator);
        defer content.deinit();
        try content.writer.writeByte('[');
        for (0..part_limit) |i| {
            if (i != 0) try content.writer.writeByte(',');
            try content.writer.writeAll(image);
        }
        try content.writer.writeAll(case.tail);
        try content.writer.writeByte(']');
        const ended: @import("mcp/result_text.zig").Ended = .{ .server_name = "test", .ended = .{ .outcome = .{ .result = .{ .content = content.written(), .structured = null, .is_error = false } } } };
        const result = try @import("tool_result.zig").Result.create(&host, 1, .{ .excerpt_bytes = 10_000, .retain = false });
        defer result.destroy();
        const rendered = renderResult(result, ended);
        try std.testing.expect(rendered == .code and rendered.code == .succeeded);
        const finished = result.finish();
        try std.testing.expect(finished == .value and finished.value == .parts);
        var cursor = finished.value.parts.cursor();
        var image_count: usize = 0;
        var text_count: usize = 0;
        while (try cursor.next()) |part| switch (part.kind) {
            .image => image_count += 1,
            .text => {
                text_count += 1;
                const expected = case.text orelse return error.TestUnexpectedResult;
                var bytes: [128]u8 = undefined;
                try std.testing.expectEqual(@as(u64, @intCast(expected.len)), part.range.length);
                try std.testing.expectEqual(expected.len, try part.range.file.readPositionalAll(std.testing.io, bytes[0..expected.len], part.range.offset));
                try std.testing.expectEqualStrings(expected, bytes[0..expected.len]);
            },
        };
        try std.testing.expectEqual(case.images, image_count);
        try std.testing.expectEqual(@as(usize, @intFromBool(case.text != null)), text_count);
    }
}

// Exercise the adapter after its response has arrived, with control changes
// committed immediately before delivery. Calls.service normally checks control
// before polling, so this is the narrow race between that check and complete.
test "MCP retained response follows the actual delivery outcome" {
    const testing = store.testing;
    const tools = @import("tools.zig");
    const retention = @import("output_retention.zig");
    const allocator = std.testing.allocator;
    const records = comptime testing.hostToolRecordsWith(&.{.{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page.", .input_schema = "{\"type\":\"object\"}" }});
    var digests: [records.len][32]u8 = undefined;
    for (&records, &digests) |*record, *digest| digest.* = tools.recordDigest(record);
    const tool_set: tools.HostToolSet = .{ .records = &records, .digests = &digests };
    const text = try allocator.alloc(u8, @import("mcp/result_text.zig").excerpt_bytes + 37);
    defer allocator.free(text);
    @memset(text, 'x');
    const content = try std.fmt.allocPrint(allocator, "[{{\"type\":\"text\",\"text\":\"{s}\"}}]", .{text});
    defer allocator.free(content);
    const ended: @import("mcp/result_text.zig").Ended = .{ .server_name = "docs", .ended = .{ .outcome = .{ .result = .{ .is_error = false, .content = content, .structured = null } } } };
    const Case = enum { normal, direct_stop, session_stop, lost, fenced };
    for (std.enums.values(Case)) |case| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const storage = try allocator.create(store.Store);
        defer allocator.destroy(storage);
        try testing.testingStoreWith(&.{ .engine = .sqlite }, storage, &tmp, std.testing.io, .{ .host_tool_set = &tool_set });
        defer storage.close() catch unreachable;
        const workspace_buffer = try allocator.create([protocol.max_workspace_bytes]u8);
        defer allocator.destroy(workspace_buffer);
        const configure = try allocator.create(@import("wire_request.zig").ConfigureCommand);
        defer allocator.destroy(configure);
        configure.* = try testing.completeConfiguration("mcp-spill-config", "", try store.testingCanonicalCwd(std.testing.io, workspace_buffer), "model-a");
        configure.configuration.tools = try .of(&.{ "bash", "fetch_page", "read_action", "stop_action" });
        configure.configuration.permission_mode.state = .value;
        try configure.configuration.permission_mode.value.set("bypass");
        const session = (try storage.configure(configure, .{})).accepted.session;
        try testing.submitTestMessage(storage, &tmp, "task", "mcp-spill-task", session.slice(), "fetch");
        const model = (try storage.admitNextModelAttempt(.{})).?.permit.binding;
        const calls = [_]store.TestingCall{
            .{ .item_id = "target", .name = "fetch_page", .encoded_call_id = "target", .decoded_call_id = "target", .encoded_arguments = "{}", .decoded_arguments = "{}" },
            .{ .item_id = "stop", .name = "stop_action", .encoded_call_id = "stop", .decoded_call_id = "stop", .encoded_arguments = "{\\\"action\\\":\\\"1\\\"}", .decoded_arguments = "{\"action\":\"1\"}" },
        };
        try store.settleCallsForTesting(storage, &tmp, model, "mcp-spill-calls", calls[0..if (case == .direct_stop) 2 else 1]);
        const selected = (try storage.nextAction(.mcp, .fromFree(2, true))).?;
        const root_buffer = try allocator.create([protocol.max_store_bytes]u8);
        defer allocator.destroy(root_buffer);
        const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, root_buffer)];
        var used: std.atomic.Value(u64) = .init(0);
        var entries: [2]retention.Entry = @splat(.{});
        var queue = retention.Queue.initialize(std.testing.io, root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, &entries);
        defer queue.cleanupAll();
        var custody_records: [1]execution.CustodyRecord = @splat(.{});
        const host = try allocator.create(Host);
        defer allocator.destroy(host);
        host.* = .{ .io = std.testing.io, .allocator = allocator, .lease = undefined, .store = storage, .custody = execution.CustodyPool.initialize(&custody_records), .retention = &queue };
        var host_parts: TestParts = undefined;
        host_parts.attach(host, undefined);
        const parts: action_attempt.Parts = .{ .store = storage, .lifecycle = host.lifecycle, .probes = host.probes, .custody = &host.custody };
        const attempt = switch (action_attempt.admit(parts, selected, 30_000, labels)) {
            .attempt => |value| value,
            else => return error.TestUnexpectedResult,
        };
        const token = attempt.token;
        defer {
            host.custody.detach(token) catch unreachable;
            host.custody.cleanupComplete(token) catch unreachable;
        }
        var active: Active = .{ .attempt = attempt, .arena = .init(allocator), .profile = @import("tool_record.zig").Runner.mcp.resultProfile(true) };
        defer active.arena.deinit();
        switch (case) {
            .direct_stop => {
                const source = (try storage.nextCoreWork(.fromFree(2, true))).?.action;
                try std.testing.expect(try storage.stopAction(source.binding, selected.action_id, .{}) == .selected);
            },
            .session_stop => {
                var stop: protocol.SessionStopCommand = .{};
                try stop.key.set("mcp-spill-stop");
                stop.session = session;
                try std.testing.expect(storage.stopSession(&stop, .{}) == .accepted);
            },
            .lost => try std.testing.expect(host.custody.claimTerminalDelivery(token)),
            .fenced => host.probes.arm(.result_before_commit),
            .normal => {},
        }
        complete(host, &active, ended);
        var filename_buffer: [128]u8 = undefined;
        const filename = try std.fmt.bufPrint(&filename_buffer, "mcp-output-{d}-1.tmp", .{selected.action_id});
        const kept = case == .normal or case == .session_stop;
        try std.testing.expectEqual(@as(usize, @intFromBool(kept)), queue.occupied());
        if (kept) {
            const contents = try tmp.dir.readFileAlloc(std.testing.io, filename, allocator, .limited(1024 * 1024));
            defer allocator.free(contents);
            try std.testing.expectEqualStrings(text, contents);
            try std.testing.expectEqual(@as(u64, @intCast(contents.len)), used.load(.acquire));
        } else {
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(std.testing.io, filename, .{}));
            try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        }
        try std.testing.expectEqual(case == .fenced, storage.isFenced());
        if (case == .normal or case == .session_stop or case == .direct_stop) {
            const resolution = if (case == .direct_stop) "cancelled" else "succeeded";
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code=?2", .{ selected.action_id, resolution }));
            const report = try store.testingSessionReportWithProfile(storage, &tmp, session.slice(), 128 * 1024, .full);
            defer allocator.free(report);
            if (case == .direct_stop) {
                try std.testing.expect(std.mem.indexOf(u8, report, "Action was stopped.") != null);
                try std.testing.expect(std.mem.indexOf(u8, report, "Full output:") == null);
            } else try std.testing.expect(std.mem.indexOf(u8, report, "Full output:") != null);
        } else {
            if (case == .fenced) {
                try storage.close();
                try testing.testingStoreWith(&.{ .engine = .sqlite }, storage, &tmp, std.testing.io, .{ .host_tool_set = &tool_set });
            }
            try std.testing.expect(try storage.recoverOneUncertainAction(.empty()));
            try std.testing.expectEqual(@as(u64, 1), try testing.queryU64(storage, "SELECT count(*) FROM action_operation WHERE action_id=?1 AND resolution_code='indeterminate'", .{selected.action_id}));
        }
    }
}
