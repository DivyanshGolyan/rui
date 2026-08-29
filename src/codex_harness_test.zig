const std = @import("std");
const codex_provider = @import("codex_provider.zig");
const harness = @import("harness.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");

const Harness = harness.Harness;
const HostRuntime = harness.HostRuntime;
const OfferResult = harness.OfferResult;
const Progress = harness.Progress;
const ProjectionKind = harness.ProjectionKind;
const State = harness.State;

fn openTestRuntime(tmp: *const std.testing.TmpDir) !*HostRuntime {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    return HostRuntime.open(std.testing.io, std.testing.allocator, path, .{});
}

test "Codex fake authorization and transport complete through the existing Harness" {
    const FakeAuthorization = struct {
        fn load(
            _: *anyopaque,
            credential: *codex_provider.Credential,
        ) anyerror!codex_provider.AuthorizationDisposition {
            @memcpy(credential.access_token[0..5], "token");
            credential.access_token_length = 5;
            @memcpy(credential.account_id[0..7], "account");
            credential.account_id_length = 7;
            return .ready;
        }
    };
    const FakeTransport = struct {
        requests: u8 = 0,

        fn perform(
            context: *anyopaque,
            _: *const codex_provider.Credential,
            request: model_operation.RequestCursor,
            capture: *codex_provider.Capture,
        ) anyerror!codex_provider.TransportDisposition {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.requests += 1;
            try codex_provider.encodeRequest(request, capture.requestSink(), &capture.mapping);
            try capture.appendSse(
                "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"completed by Codex\"}]}}\n\n" ++
                    "data: {\"type\":\"response.completed\"}\n\n",
            );
            return .complete;
        }
    };

    var fake_authorization: u8 = 0;
    var fake_transport: FakeTransport = .{};
    var codex: codex_provider.CodexProvider = .{
        .authorization = .{ .context = &fake_authorization, .load_fn = FakeAuthorization.load },
        .transport = .{ .context = &fake_transport, .perform_fn = FakeTransport.perform },
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    var owner = try Harness.open(.{
        .runtime = runtime,
        .mode = .{ .create = .{
            .workspace_path = ".",
            .model_binding = .{ .model = "codex:test-model", .provider = codex.provider() },
            .task = "task",
        } },
    });
    defer owner.close();
    _ = try owner.drive();
    try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
    _ = try owner.drive();
    const finished = try owner.drive();
    try std.testing.expectEqual(State.finished, finished.state);
    try std.testing.expectEqual(@as(u8, 1), fake_transport.requests);
    var saw_final = false;
    for (finished.projectionSlice()) |projection| {
        if (projection.kind == .final_answer) saw_final = true;
    }
    try std.testing.expect(saw_final);
}

test "Codex auth and transport failures remain typed after Harness reopen" {
    const FakeAuthorization = struct {
        disposition: codex_provider.AuthorizationDisposition,

        fn load(
            context: *anyopaque,
            credential: *codex_provider.Credential,
        ) anyerror!codex_provider.AuthorizationDisposition {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (self.disposition == .ready) {
                @memcpy(credential.access_token[0..5], "token");
                credential.access_token_length = 5;
            }
            return self.disposition;
        }
    };
    const FakeTransport = struct {
        disposition: codex_provider.TransportDisposition,
        private_http_status: ?u16 = null,
        provider_code: []const u8 = "",
        calls: u8 = 0,

        fn perform(
            context: *anyopaque,
            _: *const codex_provider.Credential,
            _: model_operation.RequestCursor,
            capture: *codex_provider.Capture,
        ) anyerror!codex_provider.TransportDisposition {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.calls += 1;
            if (self.private_http_status) |status| try capture.setFailureHttpStatus(status);
            try capture.setFailureDiagnosticCode(self.provider_code);
            return self.disposition;
        }
    };
    const Case = struct {
        authorization: codex_provider.AuthorizationDisposition = .ready,
        transport: codex_provider.TransportDisposition = .not_started,
        expected: model_protocol.Failure,
        expected_source: model_protocol.DiagnosticSource = .none,
        private_http_status: ?u16 = null,
        provider_code: []const u8 = "",
        expected_code: []const u8 = "",
    };
    const cases = [_]Case{
        .{ .authorization = .missing, .expected = .missing_authentication },
        .{
            .authorization = .refresh_rejected,
            .expected = .authentication_expired,
            .expected_source = .local_credentials,
            .expected_code = "codex.refresh.rejected",
        },
        .{
            .authorization = .refresh_missing,
            .expected = .authentication_expired,
            .expected_source = .local_credentials,
            .expected_code = "codex.refresh.missing",
        },
        .{ .authorization = .timed_out, .expected = .timeout },
        .{
            .transport = .http_unauthorized,
            .expected = .authentication_expired,
            .expected_source = .provider,
            .private_http_status = 401,
            .provider_code = "invalid_token",
            .expected_code = "codex.http.unauthorized.401",
        },
        .{
            .transport = .http_forbidden,
            .expected = .authentication_expired,
            .expected_source = .provider,
            .private_http_status = 403,
            .provider_code = "originator_not_allowed",
            .expected_code = "codex.http.forbidden.403",
        },
        .{
            .transport = .provider_rejected,
            .expected = .provider_error,
            .expected_source = .provider,
            .private_http_status = 400,
            .provider_code = "invalid_request_error",
            .expected_code = "codex.http.rejected.400",
        },
        .{
            .transport = .model_not_found,
            .expected = .model_unavailable,
            .expected_source = .provider,
            .private_http_status = 404,
            .provider_code = "model_not_found",
            .expected_code = "codex.http.model.404",
        },
        .{
            .transport = .rate_limited,
            .expected = .provider_error,
            .expected_source = .provider,
            .private_http_status = 429,
            .provider_code = "rate_limit_exceeded",
            .expected_code = "codex.http.rate.429",
        },
        .{
            .transport = .quota_exceeded,
            .expected = .provider_error,
            .expected_source = .provider,
            .private_http_status = 429,
            .provider_code = "insufficient_quota",
            .expected_code = "codex.http.quota.429",
        },
        .{
            .transport = .backend_failed,
            .expected = .provider_error,
            .expected_source = .provider,
            .private_http_status = 502,
            .provider_code = "backend_error",
            .expected_code = "codex.http.backend.502",
        },
        .{ .transport = .timed_out, .expected = .timeout },
        .{ .transport = .cancelled, .expected = .aborted },
        .{ .transport = .not_started, .expected = .transport_not_started },
        .{ .transport = .may_have_started, .expected = .transport_may_have_started },
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try openTestRuntime(&tmp);
    defer runtime.close() catch unreachable;
    for (cases, 0..) |case, index| {
        var authorization: FakeAuthorization = .{ .disposition = case.authorization };
        var transport: FakeTransport = .{
            .disposition = case.transport,
            .private_http_status = case.private_http_status,
            .provider_code = case.provider_code,
        };
        var codex: codex_provider.CodexProvider = .{
            .authorization = .{ .context = &authorization, .load_fn = FakeAuthorization.load },
            .transport = .{ .context = &transport, .perform_fn = FakeTransport.perform },
        };
        var task_buffer: [32]u8 = undefined;
        const task = try std.fmt.bufPrint(&task_buffer, "failure case {d}", .{index});
        var owner = try Harness.open(.{
            .runtime = runtime,
            .mode = .{ .create = .{
                .workspace_path = ".",
                .model_binding = .{ .model = "codex:test-model", .provider = codex.provider() },
                .task = task,
            } },
        });
        const identified = try owner.drive();
        const session_id = identified.projections[0].session_id;
        try std.testing.expectEqual(OfferResult.accepted, owner.offer(.task));
        _ = try owner.drive();
        const failed = try owner.drive();
        try std.testing.expectEqual(State.failed, failed.state);
        try std.testing.expectEqual(@as(u8, 1), failed.projection_count);
        try std.testing.expectEqual(ProjectionKind.failure, failed.projections[0].kind);
        try std.testing.expectEqual(case.expected, failed.projections[0].failure);
        try std.testing.expectEqual(case.expected_source, failed.projections[0].diagnostic_source);
        try std.testing.expectEqualStrings(case.expected_code, failed.projections[0].diagnosticCode());
        const dispatches = transport.calls;
        owner.close();

        var restored = try Harness.open(.{
            .runtime = runtime,
            .mode = .{ .restore = .{ .session_id = session_id, .model_binding = .{
                .model = "codex:test-model",
                .provider = codex.provider(),
            } } },
        });
        _ = try restored.drive();
        const reopened = try restored.drive();
        try std.testing.expectEqual(State.failed, reopened.state);
        try std.testing.expectEqual(@as(u8, 1), reopened.projection_count);
        try std.testing.expectEqual(ProjectionKind.failure, reopened.projections[0].kind);
        try std.testing.expectEqual(case.expected, reopened.projections[0].failure);
        try std.testing.expectEqual(case.expected_source, reopened.projections[0].diagnostic_source);
        try std.testing.expectEqualStrings(case.expected_code, reopened.projections[0].diagnosticCode());
        try std.testing.expectEqual(dispatches, transport.calls);
        restored.close();
    }
}
