const std = @import("std");
const host_start = @import("host_start.zig");
const host_launch = @import("host_launch.zig");
const activation = @import("host_activation.zig");

pub const Handover = struct {
    context: ?*anyopaque = null,
    activate: *const fn (?*anyopaque, std.process.Init, []const u8) anyerror!?activation.Outcome,
    spawn: *const fn (std.process.Init, host_start.Spawn, host_start.Ops, ?host_start.Progress, *host_launch.Result) void = host_start.spawn,
};

/// Attempt a handover only when an ordinary start found an incompatible Host.
pub fn spawn(init: std.process.Init, request: host_start.Spawn, ops: host_start.Ops, progress: ?host_start.Progress, result: *host_launch.Result, handover: Handover) void {
    handover.spawn(init, request, ops, progress, result);
    if (result.outcome != .failed or result.outcome.failed.cause.kind != .incompatible or request.frozen != null) return;
    const outcome = handover.activate(handover.context, init, request.dir) catch |err| {
        host_start.launchFailure(result, .setup, err, null);
        return;
    } orelse return;
    if (outcome == .ready) {
        handover.spawn(init, request, ops, progress, result);
        return;
    }
    switch (outcome) {
        .refused => |refusal| {
            host_start.launchFailure(result, .child_refused, error.HostStartupFailed, null);
            result.outcome.failed.cause.refusal_code = refusal.failure.code;
        },
        else => host_start.launchFailure(result, .setup, error.HostRestartFailed, null),
    }
    result.outcome.failed.detail = .{ .handover = outcome };
}

const Fixture = struct {
    initial: host_launch.Result.Cause.Kind = .incompatible,
    answer: ?activation.Outcome = null,
    failure: ?anyerror = null,
    spawns: usize = 0,
    activations: usize = 0,
    directory: []const u8 = "",
    requested: []const u8 = "/selected-store",

    fn launch(_: std.process.Init, request: host_start.Spawn, ops: host_start.Ops, _: ?host_start.Progress, result: *host_launch.Result) void {
        const self: *Fixture = @ptrCast(@alignCast(ops.context.?));
        self.spawns += 1;
        self.directory = request.dir;
        result.* = if (self.spawns == 1) .failed(self.initial, error.IncompatibleHost) else .failed(.worker, error.TestSecondSpawn);
    }
    fn activate(raw: ?*anyopaque, _: std.process.Init, directory: []const u8) !?activation.Outcome {
        const self: *Fixture = @ptrCast(@alignCast(raw.?));
        self.activations += 1;
        self.directory = directory;
        if (self.failure) |err| return err;
        return self.answer;
    }
    fn run(self: *Fixture, init: std.process.Init, frozen: ?[]const u8) host_launch.Result {
        var result: host_launch.Result = .failed(.setup, error.HostLaunchFailed);
        spawn(init, .{ .dir = self.requested, .frozen = frozen }, .{ .context = self }, null, &result, .{ .context = self, .activate = activate, .spawn = launch });
        return result;
    }
};

test "SH-122 ordinary start hands over only eligible incompatible Hosts and preserves every activation result" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer environment.deinit();
    const init: std.process.Init = .{ .minimal = .{ .args = .{ .vector = &.{} }, .environ = .empty }, .arena = &arena, .gpa = std.testing.allocator, .io = std.testing.io, .environ_map = &environment, .preopens = .empty };
    for ([_]struct { initial: host_launch.Result.Cause.Kind, frozen: ?[]const u8, calls: usize }{
        .{ .initial = .incompatible, .frozen = null, .calls = 1 },
        .{ .initial = .incompatible, .frozen = "frozen", .calls = 0 },
        .{ .initial = .store_access, .frozen = null, .calls = 0 },
    }) |case| {
        var fixture: Fixture = .{ .initial = case.initial };
        const result = fixture.run(init, case.frozen);
        try std.testing.expectEqual(@as(usize, 1), fixture.spawns);
        try std.testing.expectEqual(case.calls, fixture.activations);
        try std.testing.expectEqual(case.initial, result.outcome.failed.cause.kind);
        try std.testing.expect(result.outcome.failed.detail == .none);
        try std.testing.expectEqualStrings("/selected-store", fixture.directory);
    }
    for ([_]anyerror{ error.OutOfMemory, error.AccessDenied, error.FileNotFound, error.TestActivation }) |cause| {
        var failed: Fixture = .{ .failure = cause };
        const failed_result = failed.run(init, null);
        try std.testing.expectEqual(cause, failed_result.outcome.failed.cause.err);
        try std.testing.expect(failed_result.outcome.failed.detail == .none);
        try std.testing.expectEqual(@as(usize, 1), failed.activations);
    }
    const faults = [_]struct { effect: std.meta.Tag(activation.Effect), cause: []const u8, stage: ?activation.Stage }{
        .{ .effect = .resolve_target, .cause = "TestResolve", .stage = null },
        .{ .effect = .confirm_current, .cause = "TestConfirm", .stage = null },
        .{ .effect = .reconstruct_sources, .cause = "TestReconstruct", .stage = null },
        .{ .effect = .check_target, .cause = "AccessDenied", .stage = null },
        .{ .effect = .reobserve, .cause = "TestReobserve", .stage = null },
        .{ .effect = .snapshot, .cause = "TestSnapshot", .stage = null },
        .{ .effect = .stop, .cause = "BrokenPipe", .stage = .stopping },
        .{ .effect = .await_retirement, .cause = "TestRetire", .stage = .awaiting_retirement },
        .{ .effect = .start, .cause = "FileNotFound", .stage = .starting },
        .{ .effect = .verify, .cause = "OutOfMemory", .stage = .verifying },
    };
    try std.testing.expectEqual(std.meta.tags(std.meta.Tag(activation.Effect)).len - 1, faults.len);
    for (faults) |case| {
        const outcome: activation.Outcome = .{ .faulted = .{ .effect = case.effect, .cause = try .from(case.cause) } };
        var fixture: Fixture = .{ .answer = outcome };
        const result = fixture.run(init, null);
        try std.testing.expectEqual(@as(usize, 1), fixture.activations);
        try std.testing.expectEqual(@as(usize, 1), fixture.spawns);
        try std.testing.expectEqualDeep(outcome, result.outcome.failed.detail.handover);
        try std.testing.expectEqual(case.stage, outcome.faulted.effect.stage());
        var bytes: [host_launch.max_report_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try host_launch.writeDiagnostics(&result, &writer, 0);
        try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), case.cause) != null);
        const words = result.summary().failed.words();
        var signin_bytes: [512]u8 = undefined;
        var signin = std.Io.Writer.fixed(&signin_bytes);
        try host_launch.writeSignIn(&signin, result.summary(), false, true);
        try std.testing.expect(std.mem.indexOf(u8, signin.buffered(), words) != null);
        if (case.stage) |stage| {
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), @tagName(stage)) != null);
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "unconfirmed") != null);
            try std.testing.expectEqualStrings(@import("host_activation_report.zig").summary(.{ .unconfirmed = stage }), words);
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "inspect Host status") != null);
        } else {
            try std.testing.expectEqualStrings("handover failed", words);
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "Host left running") != null);
            try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "unconfirmed") == null);
        }
    }
    var long_directory: [@import("protocol.zig").max_store_bytes + 1]u8 = @splat('x');
    var long_fixture: Fixture = .{ .requested = &long_directory, .failure = error.TestActivation };
    const long_result = long_fixture.run(init, null);
    try std.testing.expectEqual(error.TestActivation, long_result.outcome.failed.cause.err);
    try std.testing.expectEqualStrings(&long_directory, long_fixture.directory);
    const instance = [_]u8{ 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42, 42 };
    const refusal = @import("start_report.zig").Failure.init(.settings_invalid, "specific refusal");
    const Case = struct { outcome: activation.Outcome, summary: []const u8, diagnostic: []const u8 };
    const outcomes = [_]Case{
        .{ .outcome = .not_needed, .summary = "no longer running", .diagnostic = "no longer running; no Host started" },
        .{ .outcome = .superseded, .summary = "newer build already running", .diagnostic = "newer than the selected build; no downgrade" },
        .{ .outcome = .{ .already_ready = .{ .instance = instance, .pid = 17 } }, .summary = "already on selected build", .diagnostic = "already on the selected build" },
        .{ .outcome = .{ .ready = .{ .instance = instance, .pid = 19 } }, .summary = "", .diagnostic = "" },
        .{ .outcome = .{ .client_incompatible = 23 }, .summary = "restarted; client incompatible", .diagnostic = "restarted with a different Host protocol" },
        .{ .outcome = .replacement_observed, .summary = "replacement Host observed", .diagnostic = "a replacement Host was observed" },
        .{ .outcome = .cancelled, .summary = "activation cancelled", .diagnostic = "failed at activation: cancelled" },
        .{ .outcome = .{ .faulted = .{ .effect = .resolve_target, .cause = try .from("TestResolve") } }, .summary = "handover failed", .diagnostic = "failed during resolve_target (TestResolve); Host left running" },
        .{ .outcome = .{ .refused = .{ .stage = .checking, .failure = refusal } }, .summary = "settings refused", .diagnostic = "these settings would not start a Host: specific refusal [settings_invalid]" },
        .{ .outcome = .{ .refused = .{ .stage = .starting, .failure = refusal } }, .summary = "refused to start", .diagnostic = "the Host did not start: specific refusal [settings_invalid]" },
        .{ .outcome = .{ .target_unusable = .resolving }, .summary = "target resolution failed", .diagnostic = "failed at resolving the target" },
        .{ .outcome = .{ .target_unusable = .checking }, .summary = "target check failed", .diagnostic = "failed at checking the target" },
    };
    for (outcomes) |case| try checkOutcome(init, case.outcome, case.summary, case.diagnostic);
    const limitations = .{
        .{ "Host inaccessible", "Store or Host is inaccessible" },
        .{ "Host protocol unsupported", "Host protocol is unsupported" },
        .{ "Host status unavailable", "Host status unavailable while owned" },
        .{ "Host observation failed", "initial Host observation failed" },
        .{ "Host directory unavailable", "Host directory could not be canonicalized" },
        .{ "Host directories differ", "Host directories differ" },
        .{ "Host identity unconfirmed", "Host identity confirmation failed" },
        .{ "application-owned Host", "application-owned Host" },
        .{ "launch configuration unavailable", "launch configuration cannot be safely reconstructed" },
        .{ "target cannot check restart", "target build cannot safely check a detached restart" },
        .{ "not eligible to start", "not eligible for an ordinary start on this build" },
    };
    inline for (std.meta.tags(activation.Limitation), limitations) |limitation, expected| {
        try checkOutcome(init, .{ .unsupported = limitation }, expected[0], expected[1]);
    }
    const stages = .{
        .{ "stop failed", "stop unconfirmed", "failed at stopping" },
        .{ "retire failed", "retire unconfirmed", "failed at awaiting_retirement" },
        .{ "start failed", "start unconfirmed", "failed at starting" },
        .{ "verify failed", "verify unconfirmed", "failed at verifying" },
    };
    inline for (std.meta.tags(activation.Stage), stages) |stage, expected| {
        try checkOutcome(init, .{ .failed = stage }, expected[0], expected[2]);
        try checkOutcome(init, .{ .unconfirmed = stage }, expected[1], expected[2]);
    }
}

fn checkOutcome(init: std.process.Init, outcome: activation.Outcome, summary: []const u8, diagnostic: []const u8) !void {
    var fixture: Fixture = .{ .answer = outcome };
    const result = fixture.run(init, null);
    try std.testing.expectEqual(@as(usize, 1), fixture.activations);
    if (outcome == .ready) {
        try std.testing.expectEqual(@as(usize, 2), fixture.spawns);
        try std.testing.expectEqual(error.TestSecondSpawn, result.outcome.failed.cause.err);
        return;
    }
    try std.testing.expectEqual(@as(usize, 1), fixture.spawns);
    try std.testing.expectEqualDeep(outcome, result.outcome.failed.detail.handover);
    try std.testing.expectEqualStrings(summary, result.summary().failed.words());
    var signin_bytes: [512]u8 = undefined;
    var signin = std.Io.Writer.fixed(&signin_bytes);
    try host_launch.writeSignIn(&signin, result.summary(), false, true);
    try std.testing.expect(std.mem.indexOf(u8, signin.buffered(), summary) != null);
    var bytes: [host_launch.max_report_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try host_launch.writeDiagnostics(&result, &writer, 0);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), diagnostic) != null);
    if (outcome == .failed) try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "restart failed") != null);
    if (outcome == .unconfirmed) try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "restart is unconfirmed") != null);
    if (outcome == .refused) {
        try std.testing.expectEqual(host_launch.Result.Cause.Kind.child_refused, result.outcome.failed.cause.kind);
        try std.testing.expectEqual(error.HostStartupFailed, result.outcome.failed.cause.err);
        try std.testing.expectEqual(outcome.refused.failure.code, result.outcome.failed.cause.refusal_code.?);
        const view = result.outcome.failed.refusalView().?;
        try std.testing.expectEqual(outcome.refused.failure.code, view.failure.code);
        try std.testing.expectEqualStrings("specific refusal", view.failure.message.slice());
        const expected = switch (outcome.refused.stage) {
            .checking => .{ @import("start_report.zig").Attempt.check, "settings refused" },
            .starting => .{ @import("start_report.zig").Attempt.start, "refused to start" },
        };
        try std.testing.expectEqual(expected[0], view.attempt);
        try std.testing.expectEqualStrings(expected[1], result.summary().failed.words());
    } else {
        try std.testing.expectEqual(error.HostRestartFailed, result.outcome.failed.cause.err);
        try std.testing.expectEqual(host_launch.Result.Cause.Kind.setup, result.outcome.failed.cause.kind);
    }
}
