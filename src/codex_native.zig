const std = @import("std");
const codex_auth = @import("codex_auth.zig");
const codex_provider = @import("codex_provider.zig");
const model_operation = @import("model_operation.zig");

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
                error.RefreshRejected, error.MissingRefreshToken => return .expired,
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
        select.async(.timeout, waitForTimeout, .{self.io});
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
        const uri = try std.Uri.parse(codex_provider.endpoint);
        var request = client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .privileged_headers = &headers,
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
        if (status == 401 or status == 403) return .authentication_failed;
        if (status == 404 or status == 429 or status >= 500) return .model_unavailable;
        if (status < 200 or status >= 300) return .may_have_started;
        var transfer_buffer: [64]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var chunk: [8192]u8 = undefined;
        while (true) {
            const read = reader.readSliceShort(&chunk) catch return .may_have_started;
            if (read == 0) break;
            capture.appendSse(chunk[0..read]) catch {
                capture.malformed = true;
                return .complete;
            };
        }
        return .complete;
    }

    fn waitForTimeout(io: std.Io) void {
        std.Io.sleep(io, std.Io.Duration.fromSeconds(transport_timeout_seconds), .awake) catch {};
    }
};

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
