const std = @import("std");
const codex_auth = @import("codex_auth.zig");
const codex_provider = @import("codex_provider.zig");
const conversation = @import("conversation.zig");
const host_store = @import("host_store.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");

const keychain_service = "OnePage Codex";
const keychain_account = "chatgpt-subscription";
const err_sec_success: i32 = 0;
const err_sec_item_not_found: i32 = -25300;
const transport_timeout_seconds: u32 = 300;

const SecKeychainItemRef = *anyopaque;
extern "Security" fn SecKeychainFindGenericPassword(
    keychain_or_array: ?*anyopaque,
    service_name_length: u32,
    service_name: [*]const u8,
    account_name_length: u32,
    account_name: [*]const u8,
    password_length: ?*u32,
    password_data: ?*?*anyopaque,
    item_ref: ?*?SecKeychainItemRef,
) i32;
extern "Security" fn SecKeychainAddGenericPassword(
    keychain: ?*anyopaque,
    service_name_length: u32,
    service_name: [*]const u8,
    account_name_length: u32,
    account_name: [*]const u8,
    password_length: u32,
    password_data: [*]const u8,
    item_ref: ?*?SecKeychainItemRef,
) i32;
extern "Security" fn SecKeychainItemModifyAttributesAndData(
    item_ref: SecKeychainItemRef,
    attr_list: ?*anyopaque,
    length: u32,
    data: [*]const u8,
) i32;
extern "Security" fn SecKeychainItemDelete(item_ref: SecKeychainItemRef) i32;
extern "Security" fn SecKeychainItemFreeContent(attr_list: ?*anyopaque, data: ?*anyopaque) i32;
extern "CoreFoundation" fn CFRelease(value: *anyopaque) void;

pub const KeychainStore = struct {
    pub fn capability(self: *KeychainStore) codex_auth.Store {
        return .{ .context = self, .load_fn = load, .save_fn = save, .delete_fn = delete };
    }

    fn load(_: *anyopaque, out: []u8) anyerror!?[]const u8 {
        var length: u32 = 0;
        var data: ?*anyopaque = null;
        const status = SecKeychainFindGenericPassword(
            null,
            keychain_service.len,
            keychain_service.ptr,
            keychain_account.len,
            keychain_account.ptr,
            &length,
            &data,
            null,
        );
        if (status == err_sec_item_not_found) return null;
        if (status != err_sec_success) return error.KeychainReadFailed;
        defer _ = SecKeychainItemFreeContent(null, data);
        if (length == 0 or length > out.len) return error.KeychainCredentialTooLarge;
        const bytes: [*]const u8 = @ptrCast(data.?);
        @memcpy(out[0..length], bytes[0..length]);
        return out[0..length];
    }

    fn save(_: *anyopaque, bytes: []const u8) anyerror!void {
        var existing: ?SecKeychainItemRef = null;
        const found = SecKeychainFindGenericPassword(
            null,
            keychain_service.len,
            keychain_service.ptr,
            keychain_account.len,
            keychain_account.ptr,
            null,
            null,
            &existing,
        );
        if (found == err_sec_success) {
            defer CFRelease(existing.?);
            if (SecKeychainItemModifyAttributesAndData(existing.?, null, @intCast(bytes.len), bytes.ptr) != err_sec_success) {
                return error.KeychainWriteFailed;
            }
            return;
        }
        if (found != err_sec_item_not_found) return error.KeychainReadFailed;
        if (SecKeychainAddGenericPassword(
            null,
            keychain_service.len,
            keychain_service.ptr,
            keychain_account.len,
            keychain_account.ptr,
            @intCast(bytes.len),
            bytes.ptr,
            null,
        ) != err_sec_success) return error.KeychainWriteFailed;
    }

    fn delete(_: *anyopaque) anyerror!void {
        var existing: ?SecKeychainItemRef = null;
        const found = SecKeychainFindGenericPassword(
            null,
            keychain_service.len,
            keychain_service.ptr,
            keychain_account.len,
            keychain_account.ptr,
            null,
            null,
            &existing,
        );
        if (found == err_sec_item_not_found) return;
        if (found != err_sec_success) return error.KeychainReadFailed;
        defer CFRelease(existing.?);
        if (SecKeychainItemDelete(existing.?) != err_sec_success) return error.KeychainDeleteFailed;
    }
};

pub const NativeHttp = struct {
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn capability(self: *NativeHttp) codex_auth.Http {
        return .{ .context = self, .post_fn = post };
    }

    fn post(
        context: *anyopaque,
        url: []const u8,
        content_type: []const u8,
        body: []const u8,
        out: []u8,
    ) anyerror!codex_auth.HttpResponse {
        const self: *NativeHttp = @ptrCast(@alignCast(context));
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        var writer = std.Io.Writer.fixed(out);
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &writer,
            .headers = .{ .content_type = .{ .override = content_type } },
        });
        return .{ .status = @intFromEnum(result.status), .body = writer.buffered() };
    }
};

pub const NativeAuthorization = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    store: codex_auth.Store,
    http: codex_auth.Http,

    pub fn capability(self: *NativeAuthorization) codex_provider.Authorization {
        return .{ .context = self, .load_fn = load };
    }

    fn load(
        context: *anyopaque,
        credential: *codex_provider.Credential,
    ) anyerror!codex_provider.AuthorizationDisposition {
        const self: *NativeAuthorization = @ptrCast(@alignCast(context));
        var stored: [3 * codex_auth.max_token_size + 1024]u8 = undefined;
        defer std.crypto.secureZero(u8, &stored);
        const bytes = (try self.store.load(&stored)) orelse return .missing;
        var tokens = try codex_auth.decodeStored(bytes);
        defer tokens.scrub();
        if (try tokenExpiresSoon(tokens.accessToken(), self.io)) {
            var renewed = codex_auth.refresh(self.http, &tokens) catch |err| switch (err) {
                error.RefreshRejected => return .refresh_rejected,
                error.MissingRefreshToken => return .refresh_missing,
                else => return err,
            };
            defer renewed.scrub();
            var encoded: [3 * codex_auth.max_token_size + 1024]u8 = undefined;
            defer std.crypto.secureZero(u8, &encoded);
            const record = try codex_auth.encodeStored(&renewed, &encoded);
            try self.store.save(record);
            tokens.scrub();
            tokens = renewed;
            renewed = .{};
        }
        @memcpy(credential.access_token[0..tokens.accessToken().len], tokens.accessToken());
        credential.access_token_length = @intCast(tokens.accessToken().len);
        @memcpy(credential.account_id[0..tokens.accountId().len], tokens.accountId());
        credential.account_id_length = @intCast(tokens.accountId().len);
        return .ready;
    }
};

pub const NativeTransport = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    endpoint: []const u8 = codex_provider.endpoint,
    timeout_seconds: u32 = transport_timeout_seconds,

    pub fn capability(self: *NativeTransport) codex_provider.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(
        context: *anyopaque,
        credential: *const codex_provider.Credential,
        request_value: model_operation.RequestCursor,
        capture: *codex_provider.Capture,
    ) anyerror!codex_provider.TransportDisposition {
        const self: *NativeTransport = @ptrCast(@alignCast(context));
        const SelectResult = union(enum) {
            request: anyerror!codex_provider.TransportDisposition,
            timeout,
        };
        var results: [2]SelectResult = undefined;
        var select = std.Io.Select(SelectResult).init(self.io, &results);
        defer select.cancelDiscard();
        select.async(.request, performRequest, .{ self, credential, request_value, capture });
        select.async(.timeout, waitForTimeout, .{ self.io, self.timeout_seconds });
        return switch (try select.await()) {
            .request => |result| result,
            .timeout => .timed_out,
        };
    }

    fn performRequest(
        self: *NativeTransport,
        credential: *const codex_provider.Credential,
        request_value: model_operation.RequestCursor,
        capture: *codex_provider.Capture,
    ) anyerror!codex_provider.TransportDisposition {
        var counter: CountingSink = .{};
        var count_mapping: codex_provider.ToolMapping = .{};
        codex_provider.encodeRequest(request_value, counter.sink(), &count_mapping) catch
            return .not_started;

        var authorization: [codex_auth.max_token_size + 8]u8 = undefined;
        defer std.crypto.secureZero(u8, &authorization);
        const bearer = try std.fmt.bufPrint(&authorization, "Bearer {s}", .{credential.token()});
        const headers = [_]std.http.Header{
            .{ .name = "authorization", .value = bearer },
            .{ .name = "chatgpt-account-id", .value = credential.accountId() },
            .{ .name = "originator", .value = "onepage" },
            .{ .name = "accept", .value = "text/event-stream" },
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "openai-beta", .value = "responses=experimental" },
        };
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const uri = try std.Uri.parse(self.endpoint);
        var request = client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .extra_headers = &headers,
        }) catch return .not_started;
        defer request.deinit();
        request.transfer_encoding = .{ .content_length = counter.count };
        var body = request.sendBodyUnflushed(&.{}) catch return .not_started;
        var body_sink: WriterSink = .{ .writer = &body.writer };
        capture.mapping = .{};
        codex_provider.encodeRequest(request_value, body_sink.sink(), &capture.mapping) catch
            return .may_have_started;
        body.end() catch return .may_have_started;
        request.connection.?.flush() catch return .may_have_started;
        var redirect_buffer: [1024]u8 = undefined;
        var response = request.receiveHead(&redirect_buffer) catch return .may_have_started;
        const status: u16 = @intFromEnum(response.head.status);
        if (status < 200 or status >= 300) {
            captureBufferedProviderFailureCode(&response, capture);
            return classifyHttpFailure(status, capture.failureDiagnosticCode());
        }
        var transfer_buffer: [64]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        while (true) {
            const chunk = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return .may_have_started,
            };
            capture.appendSse(chunk) catch {
                capture.malformed = true;
                return .complete;
            };
            reader.toss(chunk.len);
            if (capture.terminalObserved()) return .complete;
        }
        return .complete;
    }

    fn waitForTimeout(io: std.Io, seconds: u32) void {
        std.Io.sleep(io, std.Io.Duration.fromSeconds(seconds), .awake) catch {};
    }
};

fn captureBufferedProviderFailureCode(
    response: *std.http.Client.Response,
    capture: *codex_provider.Capture,
) void {
    const length = response.head.content_length orelse return;
    if (length == 0 or length > 4096 or response.head.transfer_encoding != .none or
        response.head.content_encoding != .identity)
    {
        return;
    }
    const buffered = response.request.connection.?.reader().buffered();
    if (buffered.len < length) return;
    setProviderFailureCode(buffered[0..@intCast(length)], capture);
}

fn classifyHttpFailure(status: u16, code: []const u8) codex_provider.TransportDisposition {
    if (status == 401) return .http_unauthorized;
    if (status == 403) return .http_forbidden;
    if (status >= 500) return .backend_failed;
    if (status == 429) {
        if (codeIsOneOf(code, &.{ "insufficient_quota", "usage_limit_reached", "quota_exceeded" })) {
            return .quota_exceeded;
        }
        return .rate_limited;
    }
    if (status == 404 and codeIsOneOf(code, &.{ "model_not_found", "model_not_available" })) {
        return .model_not_found;
    }
    return .provider_rejected;
}

fn codeIsOneOf(code: []const u8, expected: []const []const u8) bool {
    for (expected) |candidate| if (std.mem.eql(u8, code, candidate)) return true;
    return false;
}

fn setProviderFailureCode(body: []const u8, capture: *codex_provider.Capture) void {
    var arena_bytes: [8192]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena_bytes);
    var parsed = std.json.parseFromSlice(std.json.Value, fixed.allocator(), body, .{
        .max_value_len = 4096,
        .duplicate_field_behavior = .@"error",
    }) catch return;
    defer parsed.deinit();
    const outer = switch (parsed.value) {
        .object => |value| value,
        else => return,
    };
    const error_value = outer.get("error") orelse return;
    const error_object = switch (error_value) {
        .object => |value| value,
        else => return,
    };
    const code_value = error_object.get("code") orelse error_object.get("type") orelse return;
    const code = switch (code_value) {
        .string => |value| value,
        else => return,
    };
    capture.setFailureDiagnosticCode(code) catch {};
}

const CountingSink = struct {
    count: u64 = 0,
    fn sink(self: *CountingSink) codex_provider.ByteSink {
        return .{ .context = self, .write_fn = write };
    }
    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *CountingSink = @ptrCast(@alignCast(context));
        self.count = std.math.add(u64, self.count, bytes.len) catch return error.RequestTooLarge;
    }
};

const WriterSink = struct {
    writer: *std.Io.Writer,
    fn sink(self: *WriterSink) codex_provider.ByteSink {
        return .{ .context = self, .write_fn = write };
    }
    fn write(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *WriterSink = @ptrCast(@alignCast(context));
        try self.writer.writeAll(bytes);
    }
};

fn tokenExpiresSoon(token: []const u8, io: std.Io) !bool {
    var pieces = std.mem.splitScalar(u8, token, '.');
    _ = pieces.next() orelse return true;
    const payload = pieces.next() orelse return true;
    var decoded: [codex_auth.max_token_size]u8 = undefined;
    defer std.crypto.secureZero(u8, &decoded);
    const length = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload) catch return true;
    if (length > decoded.len) return true;
    std.base64.url_safe_no_pad.Decoder.decode(decoded[0..length], payload) catch return true;
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, decoded[0..length], .{}) catch return true;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return true,
    };
    const expiry = switch (object.get("exp") orelse return true) {
        .integer => |value| value,
        else => return true,
    };
    const now = std.Io.Clock.real.now(io).toSeconds();
    return expiry <= now + 300;
}

test "live-shaped integer expiry does not force premature refresh" {
    const token = "e30.eyJleHAiOjQxMDI0NDQ4MDAsImh0dHBzOi8vYXBpLm9wZW5haS5jb20vYXV0aCI6eyJjaGF0Z3B0X2FjY291bnRfaWQiOiJhY2NvdW50In19.sig";
    try std.testing.expect(!try tokenExpiresSoon(token, std.testing.io));
}

test "HTTP diagnostics retain only bounded provider error code or type" {
    var capture: codex_provider.Capture = .{};
    setProviderFailureCode(
        "{\"error\":{\"code\":\"originator_not_allowed\",\"message\":\"unbounded secret-adjacent text\"}}",
        &capture,
    );
    try std.testing.expectEqualStrings("originator_not_allowed", capture.failureDiagnosticCode());

    setProviderFailureCode("{\"error\":{\"type\":\"invalid_request_error\"}}", &capture);
    try std.testing.expectEqualStrings("invalid_request_error", capture.failureDiagnosticCode());

    setProviderFailureCode("{\"error\":{\"code\":\"not a bounded code\"}}", &capture);
    try std.testing.expectEqualStrings("invalid_request_error", capture.failureDiagnosticCode());
}

test "NativeTransport sends the production request and stops at terminal SSE" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1001, 1, 1);
    var provider_io = try model_operation.ProviderIo.open(&wire.session, 1001, 1002);
    defer provider_io.close();

    const response =
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"done\"}]}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";
    var fixture = try WireFixture.init(io, .ok, response, true);
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });

    var endpoint_buffer: [128]u8 = undefined;
    const local_endpoint = try fixture.endpoint(&endpoint_buffer);
    var transport: NativeTransport = .{
        .io = io,
        .allocator = std.testing.allocator,
        .endpoint = local_endpoint,
        .timeout_seconds = 1,
    };
    var credential = fakeCredential();
    defer credential.scrub();
    var capture: codex_provider.Capture = .{};
    const capability = transport.capability();
    const disposition = capability.perform_fn(
        capability.context,
        &credential,
        try provider_io.request(),
        &capture,
    );
    const server_result = server_future.cancel(io);
    server_result catch |err| if (err != error.Canceled) return err;

    try std.testing.expectEqual(codex_provider.TransportDisposition.complete, try disposition);
    try std.testing.expect(capture.terminalObserved());
    try fixture.expectProductionRequest(false);
}

test "NativeTransport lowers a two-turn tool result on the production wire" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);

    var call_buffer: [256]u8 = undefined;
    const call_bytes = try conversation.encodeToolCall(&call_buffer, .{
        .key = "bash.v1",
        .arguments = try modelContractJson("{\"command\":\"true\",\"timeout_ms\":1000}"),
    });
    try wire.session.storeBlob(1100, call_bytes);
    const call = try wire.session.appendConversation(.tool_call, 1100, null);
    try commitConversation(&wire.session, call);
    var result_buffer: [256]u8 = undefined;
    const result_bytes = try conversation.encodeToolResult(&result_buffer, .{
        .parent_id = call.entry_id,
        .is_error = false,
        .content = "exit_code=0",
    });
    try wire.session.storeBlob(1101, result_bytes);
    const result = try wire.session.appendConversation(.tool_result, 1101, null);
    try commitConversation(&wire.session, result);
    _ = try model_operation.buildRequest(&wire.session, 1102, 1, 3);
    var provider_io = try model_operation.ProviderIo.open(&wire.session, 1102, 1103);
    defer provider_io.close();

    const response =
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"verified\"}]}}\n\n" ++
        "data: {\"type\":\"response.done\",\"response\":{\"status\":\"completed\"}}\n\n";
    var fixture = try WireFixture.init(io, .ok, response, false);
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });
    var endpoint_buffer: [128]u8 = undefined;
    var transport: NativeTransport = .{
        .io = io,
        .allocator = std.testing.allocator,
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .timeout_seconds = 1,
    };
    var credential = fakeCredential();
    defer credential.scrub();
    var capture: codex_provider.Capture = .{};
    const capability = transport.capability();
    const disposition = try capability.perform_fn(
        capability.context,
        &credential,
        try provider_io.request(),
        &capture,
    );
    try server_future.await(io);
    try std.testing.expectEqual(codex_provider.TransportDisposition.complete, disposition);
    try fixture.expectProductionRequest(true);
}

test "NativeTransport classifies every received HTTP rejection without retry" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1200, 1, 1);
    const cases = [_]struct {
        status: std.http.Status,
        code: []const u8,
        expected: codex_provider.TransportDisposition,
    }{
        .{ .status = .bad_request, .code = "invalid_request_error", .expected = .provider_rejected },
        .{ .status = .unauthorized, .code = "invalid_token", .expected = .http_unauthorized },
        .{ .status = .forbidden, .code = "originator_not_allowed", .expected = .http_forbidden },
        .{ .status = .not_found, .code = "model_not_found", .expected = .model_not_found },
        .{ .status = .too_many_requests, .code = "rate_limit_exceeded", .expected = .rate_limited },
        .{ .status = .too_many_requests, .code = "insufficient_quota", .expected = .quota_exceeded },
        .{ .status = .service_unavailable, .code = "backend_error", .expected = .backend_failed },
    };
    for (cases, 0..) |case, index| {
        var body_buffer: [256]u8 = undefined;
        const body = try std.fmt.bufPrint(
            &body_buffer,
            "{{\"error\":{{\"code\":\"{s}\",\"message\":\"discard this message\"}}}}",
            .{case.code},
        );
        var fixture = try WireFixture.init(io, case.status, body, false);
        defer fixture.deinit(io);
        var server_future = io.async(WireFixture.serve, .{ &fixture, io });
        var endpoint_buffer: [128]u8 = undefined;
        var transport: NativeTransport = .{
            .io = io,
            .allocator = std.testing.allocator,
            .endpoint = try fixture.endpoint(&endpoint_buffer),
            .timeout_seconds = 1,
        };
        var credential = fakeCredential();
        defer credential.scrub();
        var capture: codex_provider.Capture = .{};
        var provider_io = try model_operation.ProviderIo.open(
            &wire.session,
            1200,
            1201 + index,
        );
        defer provider_io.close();
        const capability = transport.capability();
        const disposition = try capability.perform_fn(
            capability.context,
            &credential,
            try provider_io.request(),
            &capture,
        );
        try server_future.await(io);
        try std.testing.expectEqual(case.expected, disposition);
        try std.testing.expectEqualStrings(case.code, capture.failureDiagnosticCode());
    }
}

fn modelContractJson(bytes: []const u8) !@import("model_contract.zig").StrictToolJson {
    var scratch: @import("model_contract.zig").StrictToolJsonScratch = undefined;
    return @import("model_contract.zig").validateStrictToolJson(&scratch, bytes);
}

fn fakeCredential() codex_provider.Credential {
    var credential: codex_provider.Credential = .{};
    @memcpy(credential.access_token[0.."fake-access".len], "fake-access");
    credential.access_token_length = "fake-access".len;
    @memcpy(credential.account_id[0.."fake-account".len], "fake-account");
    credential.account_id_length = "fake-account".len;
    return credential;
}

const WireSession = struct {
    storage: *host_store.StorageOwner,
    sessions: std.Io.Dir,
    session: session_store.Session,

    fn init(io: std.Io, tmp: *const std.testing.TmpDir) !WireSession {
        try tmp.dir.createDir(io, "sessions", .default_dir);
        try tmp.dir.createDir(io, "repo", .default_dir);
        var repo = try tmp.dir.openDir(io, "repo", .{});
        defer repo.close(io);
        try repo.createDir(io, ".git", .default_dir);
        var git_dir = try repo.openDir(io, ".git", .{});
        defer git_dir.close(io);
        try git_dir.createDir(io, "objects", .default_dir);
        try git_dir.createDir(io, "refs", .default_dir);
        var config = try git_dir.createFile(io, "config", .{});
        defer config.close(io);
        try config.writePositionalAll(io, "[core]\n\trepositoryformatversion = 0\n", 0);
        var head = try git_dir.createFile(io, "HEAD", .{});
        defer head.close(io);
        try head.writePositionalAll(io, "ref: refs/heads/main\n", 0);
        const sessions = try tmp.dir.openDir(io, "sessions", .{});
        errdefer sessions.close(io);
        var database_path_buffer: [128]u8 = undefined;
        const database_path = try std.fmt.bufPrint(
            &database_path_buffer,
            ".zig-cache/tmp/{s}/host.sqlite3",
            .{tmp.sub_path},
        );
        const storage = try std.testing.allocator.create(host_store.StorageOwner);
        errdefer std.testing.allocator.destroy(storage);
        storage.* = try host_store.StorageOwner.open(io, database_path, .{});
        errdefer storage.close();
        var path_buffer: [128]u8 = undefined;
        const workspace_path = try std.fmt.bufPrint(
            &path_buffer,
            ".zig-cache/tmp/{s}/repo",
            .{tmp.sub_path},
        );
        const session = try session_store.Session.create(sessions, storage, io, .{
            .workspace_path = workspace_path,
            .model = "codex:gpt-5.1-codex-mini",
            .task = "Inspect the repository",
        });
        return .{ .storage = storage, .sessions = sessions, .session = session };
    }

    fn deinit(self: *WireSession, io: std.Io) void {
        self.session.close();
        self.storage.close();
        std.testing.allocator.destroy(self.storage);
        self.sessions.close(io);
    }
};

fn commitConversation(session: *session_store.Session, entry: session_store.ConversationEntry) !void {
    _ = try session.commitSemantic(&.{session_transition.conversationAdvanced(.{
        .agent = .{
            .agent_id = session.agent_id,
            .agent_generation = 1,
            .ownership_epoch = session.ownership_epoch,
        },
        .entry_id = entry.entry_id,
        .parent_id = entry.parent_id,
        .kind = entry.kind,
        .content_ref = entry.content_ref,
    })}, null);
}

const WireFixture = struct {
    listener: std.Io.net.Server,
    status: std.http.Status,
    response: []const u8,
    keep_open: bool,
    method: std.http.Method = .GET,
    target: [128]u8 = @splat(0),
    target_length: usize = 0,
    authorization: bool = false,
    account: bool = false,
    originator: bool = false,
    accept: bool = false,
    content_type: bool = false,
    beta: bool = false,
    body: [96 * 1024]u8 = undefined,
    body_length: usize = 0,

    fn init(io: std.Io, status: std.http.Status, response: []const u8, keep_open: bool) !WireFixture {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{
            .listener = try address.listen(io, .{}),
            .status = status,
            .response = response,
            .keep_open = keep_open,
        };
    }

    fn deinit(self: *WireFixture, io: std.Io) void {
        self.listener.deinit(io);
    }

    fn endpoint(self: *const WireFixture, out: []u8) ![]const u8 {
        return std.fmt.bufPrint(
            out,
            "http://127.0.0.1:{d}/backend-api/codex/responses",
            .{self.listener.socket.address.getPort()},
        );
    }

    fn serve(self: *WireFixture, io: std.Io) anyerror!void {
        const stream = try self.listener.accept(io);
        defer stream.close(io);
        var read_buffer: [128 * 1024]u8 = undefined;
        var write_buffer: [4096]u8 = undefined;
        var stream_reader = stream.reader(io, &read_buffer);
        var stream_writer = stream.writer(io, &write_buffer);
        var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = try server.receiveHead();
        self.method = request.head.method;
        if (request.head.target.len > self.target.len) return error.TargetTooLarge;
        @memcpy(self.target[0..request.head.target.len], request.head.target);
        self.target_length = request.head.target.len;
        var headers = request.iterateHeaders();
        while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                self.authorization = std.mem.eql(u8, header.value, "Bearer fake-access");
            } else if (std.ascii.eqlIgnoreCase(header.name, "chatgpt-account-id")) {
                self.account = std.mem.eql(u8, header.value, "fake-account");
            } else if (std.ascii.eqlIgnoreCase(header.name, "originator")) {
                self.originator = std.mem.eql(u8, header.value, "onepage");
            } else if (std.ascii.eqlIgnoreCase(header.name, "accept")) {
                self.accept = std.mem.eql(u8, header.value, "text/event-stream");
            } else if (std.ascii.eqlIgnoreCase(header.name, "content-type")) {
                self.content_type = std.mem.eql(u8, header.value, "application/json");
            } else if (std.ascii.eqlIgnoreCase(header.name, "openai-beta")) {
                self.beta = std.mem.eql(u8, header.value, "responses=experimental");
            }
        }
        const body_length = request.head.content_length orelse return error.MissingContentLength;
        if (body_length > self.body.len) return error.RequestBodyTooLarge;
        const body_reader = try request.readerExpectContinue(&.{});
        try body_reader.readSliceAll(self.body[0..@intCast(body_length)]);
        self.body_length = @intCast(body_length);
        if (!self.keep_open) {
            try request.respond(self.response, .{
                .status = self.status,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
            });
            return;
        }
        var response_buffer: [4096]u8 = undefined;
        var response_writer = try request.respondStreaming(&response_buffer, .{
            .content_length = self.response.len + 1,
            .respond_options = .{
                .status = self.status,
                .extra_headers = &.{.{ .name = "content-type", .value = "text/event-stream" }},
            },
        });
        try response_writer.writer.writeAll(self.response);
        try response_writer.writer.flush();
        try response_writer.flush();
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(5), .awake);
    }

    fn expectProductionRequest(self: *const WireFixture, two_turn: bool) !void {
        try std.testing.expectEqual(std.http.Method.POST, self.method);
        try std.testing.expectEqualStrings(
            "/backend-api/codex/responses",
            self.target[0..self.target_length],
        );
        try std.testing.expect(self.authorization);
        try std.testing.expect(self.account);
        try std.testing.expect(self.originator);
        try std.testing.expect(self.accept);
        try std.testing.expect(self.content_type);
        try std.testing.expect(self.beta);
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            self.body[0..self.body_length],
            .{ .duplicate_field_behavior = .@"error" },
        );
        defer parsed.deinit();
        const object = switch (parsed.value) {
            .object => |value| value,
            else => return error.ExpectedRequestObject,
        };
        try std.testing.expectEqualStrings("gpt-5.1-codex-mini", object.get("model").?.string);
        try std.testing.expect(!object.get("store").?.bool);
        try std.testing.expect(object.get("stream").?.bool);
        try std.testing.expect(!object.get("parallel_tool_calls").?.bool);
        try std.testing.expectEqualStrings("auto", object.get("tool_choice").?.string);
        const input = object.get("input").?.array;
        try std.testing.expectEqual(@as(usize, if (two_turn) 3 else 1), input.items.len);
        try std.testing.expectEqualStrings("user", input.items[0].object.get("role").?.string);
        if (two_turn) {
            try std.testing.expectEqualStrings("function_call", input.items[1].object.get("type").?.string);
            try std.testing.expectEqualStrings("onepage_2", input.items[1].object.get("call_id").?.string);
            try std.testing.expectEqualStrings("function_call_output", input.items[2].object.get("type").?.string);
            try std.testing.expectEqualStrings("onepage_2", input.items[2].object.get("call_id").?.string);
            try std.testing.expectEqualStrings("exit_code=0", input.items[2].object.get("output").?.string);
        }
    }
};
