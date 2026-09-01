const std = @import("std");
const builtin = @import("builtin");
const codex_auth = @import("codex_auth.zig");
const codex_provider = @import("codex_provider.zig");
const conversation = @import("conversation.zig");
const host_store = @import("host_store.zig");
const model_contract = @import("model_contract.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");
const session_store = @import("session.zig");
const session_transition = @import("session_transition.zig");
const c = @cImport({
    @cInclude("curl/curl.h");
});

const keychain_service = "OnePage Codex";
const keychain_account = "chatgpt-subscription";
const err_sec_success: i32 = 0;
const err_sec_item_not_found: i32 = -25300;
const transport_timeout = codex_auth.request_timeout;
const minimum_curl_version: c_uint = 0x075500; // 7.85.0: thread-safe lifecycle and protocol strings.
const authorization_header_prefix = "Authorization: Bearer ";
const authorization_header_capacity = authorization_header_prefix.len + codex_auth.max_token_size + 1;

const CurlInitState = enum(u8) { uninitialized, initializing, ready, failed };
var curl_init_state: std.atomic.Value(CurlInitState) = .init(.uninitialized);

pub fn initializeModelTransport() !void {
    while (true) switch (curl_init_state.load(.acquire)) {
        .ready => return,
        .failed => return error.UnsupportedSystemCurl,
        .initializing => std.atomic.spinLoopHint(),
        .uninitialized => {
            if (curl_init_state.cmpxchgStrong(
                .uninitialized,
                .initializing,
                .acq_rel,
                .acquire,
            ) != null) continue;
            if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) {
                curl_init_state.store(.failed, .release);
                return error.UnsupportedSystemCurl;
            }
            if (!systemCurlSupported()) {
                c.curl_global_cleanup();
                curl_init_state.store(.failed, .release);
                return error.UnsupportedSystemCurl;
            }
            curl_init_state.store(.ready, .release);
            return;
        },
    };
}

pub fn deinitializeModelTransport() void {
    if (curl_init_state.cmpxchgStrong(.ready, .initializing, .acq_rel, .acquire) != null) return;
    c.curl_global_cleanup();
    curl_init_state.store(.uninitialized, .release);
}

fn systemCurlSupported() bool {
    const info = c.curl_version_info(c.CURLVERSION_NOW) orelse return false;
    if (info.*.version_num < minimum_curl_version or
        info.*.ssl_version == null or
        info.*.protocols == null or
        info.*.features & c.CURL_VERSION_SSL == 0 or
        info.*.features & c.CURL_VERSION_ASYNCHDNS == 0 or
        info.*.features & c.CURL_VERSION_THREADSAFE == 0)
    {
        return false;
    }
    var index: usize = 0;
    while (info.*.protocols[index] != null) : (index += 1) {
        if (std.mem.eql(u8, std.mem.span(info.*.protocols[index]), "https")) return true;
    }
    return false;
}

pub const response_head_window_size: usize = 1024;
pub const diagnostic_body_limit: usize = 4096;
pub const diagnostic_transfer_window_size: usize = 1024;

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
    timeout: std.Io.Duration = transport_timeout,
    authorization_origin_override: ?[]const u8 = null,

    pub fn capability(self: *NativeHttp) codex_auth.Http {
        return .{ .context = self, .post_fn = post, .timeout = self.timeout };
    }

    fn post(
        context: *anyopaque,
        url: []const u8,
        content_type: []const u8,
        body: []const u8,
        out: []u8,
        timeout: std.Io.Duration,
    ) anyerror!codex_auth.HttpResponse {
        const self: *NativeHttp = @ptrCast(@alignCast(context));
        var rewritten_url: [512]u8 = undefined;
        const request_url = if (self.authorization_origin_override) |origin| blk: {
            if (!std.mem.startsWith(u8, url, codex_auth.issuer)) return error.UnexpectedAuthorizationOrigin;
            break :blk try std.fmt.bufPrint(
                &rewritten_url,
                "{s}{s}",
                .{ origin, url[codex_auth.issuer.len..] },
            );
        } else url;
        const Result = union(enum) {
            request: anyerror!codex_auth.HttpResponse,
            timeout,
        };
        var request_control: RequestControl = .{};
        var completed_response: ?codex_auth.HttpResponse = null;
        var results: [2]Result = undefined;
        var select = std.Io.Select(Result).init(self.io, &results);
        select.async(.request, postRequest, .{
            self,
            request_url,
            content_type,
            body,
            out,
            &request_control,
            &completed_response,
        });
        select.async(.timeout, waitHttpTimeout, .{ self.io, timeout, &request_control });
        const selected = try select.await();
        select.cancelDiscard();
        if (request_control.winnerValue(self.io) == .timed_out) return error.HttpRequestTimedOut;
        return switch (selected) {
            .request => |result| result catch |err| switch (err) {
                error.OutOfMemory,
                error.UnexpectedAuthorizationOrigin,
                => return err,
                else => error.AuthorizationTransportFailed,
            },
            .timeout => if (request_control.winnerValue(self.io) == .terminal)
                completed_response orelse error.IncompleteHttpResponse
            else
                error.HttpRequestTimedOut,
        };
    }

    fn postRequest(
        self: *NativeHttp,
        url: []const u8,
        content_type: []const u8,
        body: []const u8,
        out: []u8,
        request_control: *RequestControl,
        completed_response: *?codex_auth.HttpResponse,
    ) !codex_auth.HttpResponse {
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();
        const uri = try std.Uri.parse(url);
        const headers = [_]std.http.Header{.{ .name = "content-type", .value = content_type }};
        var request = try client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .keep_alive = false,
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .extra_headers = &headers,
        });
        defer request.deinit();
        request_control.publish(self.io, request.connection.?.stream_reader.stream);
        defer request_control.clear(self.io);
        request.transfer_encoding = .{ .content_length = body.len };
        var request_body = try request.sendBodyUnflushed(&.{});
        try request_body.writer.writeAll(body);
        try request_body.end();
        try request.connection.?.flush();
        var redirect_buffer: [response_head_window_size]u8 = undefined;
        var response = try request.receiveHead(&redirect_buffer);
        if (response.head.content_encoding != .identity) {
            const status: u16 = @intFromEnum(response.head.status);
            if (status >= 200 and status < 300) return error.UnexpectedContentEncoding;
            const result: codex_auth.HttpResponse = .{ .status = status, .body = "" };
            completed_response.* = result;
            request_control.observeComplete(self.io);
            return result;
        }
        var transfer_buffer: [diagnostic_transfer_window_size]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        var length: usize = 0;
        while (true) {
            const chunk = reader.peekGreedy(1) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (chunk.len > out.len - length) return error.HttpResponseTooLarge;
            @memcpy(out[length..][0..chunk.len], chunk);
            length += chunk.len;
            reader.toss(chunk.len);
        }
        const result: codex_auth.HttpResponse = .{
            .status = @intFromEnum(response.head.status),
            .body = out[0..length],
        };
        completed_response.* = result;
        request_control.observeComplete(self.io);
        return result;
    }

    fn waitHttpTimeout(io: std.Io, duration: std.Io.Duration, request_control: *RequestControl) void {
        std.Io.sleep(io, duration, .awake) catch return;
        request_control.interrupt(io);
    }
};

pub const NativeAuthorization = struct {
    io: std.Io,
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
                error.HttpRequestTimedOut => return .timed_out,
                error.AuthorizationTransportFailed => return .failed,
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
    endpoint: []const u8 = codex_provider.endpoint,
    timeout: std.Io.Duration = transport_timeout,

    pub fn capability(self: *NativeTransport) codex_provider.Transport {
        return .{ .context = self, .perform_fn = perform };
    }

    fn perform(
        context: *anyopaque,
        credential: *const codex_provider.Credential,
        request_value: model_operation.RequestCursor,
        capture: *codex_provider.Capture,
    ) anyerror!codex_provider.TransportResult {
        const self: *NativeTransport = @ptrCast(@alignCast(context));
        try initializeModelTransport();
        const content_length: u64 = length: {
            var count_mapping: codex_provider.ToolMapping = .{};
            var count_reader = try codex_provider.RequestReader.init(request_value, &count_mapping);
            var count_window: [codex_provider.request_window_size]u8 = undefined;
            var length: u64 = 0;
            while (true) {
                const count = try count_reader.read(&count_window);
                if (count == 0) break;
                length = std.math.add(u64, length, count) catch
                    return error.ProviderRequestTooLarge;
            }
            break :length length;
        };

        var transfer: EasyTransfer = .{
            .io = self.io,
            .reader = try codex_provider.RequestReader.init(request_value, &capture.mapping),
            .capture = capture,
        };
        var endpoint_buffer: [512]u8 = undefined;
        const endpoint = try std.fmt.bufPrintZ(&endpoint_buffer, "{s}", .{self.endpoint});
        if (!builtin.is_test and !std.mem.startsWith(u8, self.endpoint, "https://")) {
            return error.InvalidProviderEndpoint;
        }

        var authorization: [authorization_header_capacity]u8 = undefined;
        defer std.crypto.secureZero(u8, &authorization);
        const bearer = try std.fmt.bufPrintZ(
            &authorization,
            authorization_header_prefix ++ "{s}",
            .{credential.token()},
        );
        var account_header_buffer: [codex_provider.max_account_id_size + 32]u8 = undefined;
        const account_header = try std.fmt.bufPrintZ(
            &account_header_buffer,
            "ChatGPT-Account-Id: {s}",
            .{credential.accountId()},
        );
        var headers: ?*c.struct_curl_slist = null;
        defer c.curl_slist_free_all(headers);
        const fixed_headers = [_][*:0]const u8{
            "Originator: onepage",
            "Accept: text/event-stream",
            "Content-Type: application/json",
            "Accept-Encoding: identity",
            "OpenAI-Beta: responses=experimental",
            "Expect:",
        };
        headers = try appendCurlHeader(headers, bearer.ptr);
        headers = try appendCurlHeader(headers, account_header.ptr);
        for (fixed_headers) |header| headers = try appendCurlHeader(headers, header);

        const easy = c.curl_easy_init() orelse return error.CurlEasyInitFailed;
        defer c.curl_easy_cleanup(easy);
        const timeout_ms = durationMilliseconds(self.timeout);
        try setCurlOption(easy, c.CURLOPT_URL, endpoint.ptr);
        try setCurlOption(easy, c.CURLOPT_HTTPHEADER, headers);
        try setCurlOption(easy, c.CURLOPT_POST, @as(c_long, 1));
        try setCurlOption(easy, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(content_length)));
        try setCurlOption(easy, c.CURLOPT_READFUNCTION, &EasyTransfer.readCallback);
        try setCurlOption(easy, c.CURLOPT_READDATA, &transfer);
        try setCurlOption(easy, c.CURLOPT_WRITEFUNCTION, &EasyTransfer.writeCallback);
        try setCurlOption(easy, c.CURLOPT_WRITEDATA, &transfer);
        try setCurlOption(easy, c.CURLOPT_HEADERFUNCTION, &EasyTransfer.headerCallback);
        try setCurlOption(easy, c.CURLOPT_HEADERDATA, &transfer);
        try setCurlOption(easy, c.CURLOPT_XFERINFOFUNCTION, &EasyTransfer.progressCallback);
        try setCurlOption(easy, c.CURLOPT_XFERINFODATA, &transfer);
        try setCurlOption(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        try setCurlOption(easy, c.CURLOPT_TIMEOUT_MS, timeout_ms);
        try setCurlOption(easy, c.CURLOPT_CONNECTTIMEOUT_MS, timeout_ms);
        try setCurlOption(easy, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        try setCurlOption(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        try setCurlOption(easy, c.CURLOPT_MAXREDIRS, @as(c_long, 0));
        try setCurlOption(easy, c.CURLOPT_PROXY, @as([*:0]const u8, ""));
        try setCurlOption(easy, c.CURLOPT_ACCEPT_ENCODING, @as([*:0]const u8, "identity"));
        try setCurlOption(easy, c.CURLOPT_HTTP_CONTENT_DECODING, @as(c_long, 0));
        try setCurlOption(easy, c.CURLOPT_HTTP_VERSION, @as(c_long, c.CURL_HTTP_VERSION_1_1));
        try setCurlOption(easy, c.CURLOPT_FRESH_CONNECT, @as(c_long, 1));
        try setCurlOption(easy, c.CURLOPT_FORBID_REUSE, @as(c_long, 1));
        try setCurlOption(easy, c.CURLOPT_NETRC, @as(c_long, c.CURL_NETRC_IGNORED));
        try setCurlOption(easy, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1));
        try setCurlOption(easy, c.CURLOPT_SSL_VERIFYHOST, @as(c_long, 2));
        if (@hasDecl(c, "CURLOPT_PROTOCOLS_STR")) {
            try setCurlOption(
                easy,
                c.CURLOPT_PROTOCOLS_STR,
                @as([*:0]const u8, if (builtin.is_test) "http,https" else "https"),
            );
        } else {
            const protocols = c.CURLPROTO_HTTPS | if (builtin.is_test) c.CURLPROTO_HTTP else 0;
            try setCurlOption(easy, c.CURLOPT_PROTOCOLS, @as(c_long, protocols));
        }

        const code = c.curl_easy_perform(easy);
        return transfer.result(code);
    }
};

const EasyTransfer = struct {
    const CallbackDisposition = union(enum) {
        none,
        terminal_observed,
        cancelled,
        invalid_encoding,
        capture_resource_exceeded,
        host_error: anyerror,
    };

    io: std.Io,
    reader: codex_provider.RequestReader,
    capture: *codex_provider.Capture,
    status: u16 = 0,
    encoding_is_identity: bool = true,
    diagnostic: [diagnostic_body_limit + 1]u8 = undefined,
    diagnostic_length: usize = 0,
    diagnostic_overflowed: bool = false,
    upload_bytes: u64 = 0,
    disposition: CallbackDisposition = .none,

    fn readCallback(
        pointer: [*]u8,
        size: usize,
        count: usize,
        userdata: ?*anyopaque,
    ) callconv(.c) usize {
        const self: *EasyTransfer = @ptrCast(@alignCast(userdata orelse
            return c.CURL_READFUNC_ABORT));
        const capacity = std.math.mul(usize, size, count) catch {
            self.recordDisposition(.{ .host_error = error.ProviderRequestWriteFailed });
            return c.CURL_READFUNC_ABORT;
        };
        if (capacity == 0) return 0;
        std.Io.checkCancel(self.io) catch {
            self.recordDisposition(.cancelled);
            return c.CURL_READFUNC_ABORT;
        };
        const written = self.reader.read(pointer[0..capacity]) catch |err| {
            self.recordDisposition(.{ .host_error = err });
            return c.CURL_READFUNC_ABORT;
        };
        self.upload_bytes = std.math.add(u64, self.upload_bytes, written) catch {
            self.recordDisposition(.{ .host_error = error.ProviderRequestTooLarge });
            return c.CURL_READFUNC_ABORT;
        };
        return written;
    }

    fn writeCallback(
        pointer: [*]u8,
        size: usize,
        count: usize,
        userdata: ?*anyopaque,
    ) callconv(.c) usize {
        const self: *EasyTransfer = @ptrCast(@alignCast(userdata orelse return 0));
        const length = std.math.mul(usize, size, count) catch return 0;
        const bytes = pointer[0..length];
        std.Io.checkCancel(self.io) catch {
            self.recordDisposition(.cancelled);
            return 0;
        };
        if (!self.encoding_is_identity) {
            self.recordDisposition(.invalid_encoding);
            return 0;
        }
        if (self.status < 200 or self.status >= 300) {
            self.appendDiagnostic(bytes);
            return length;
        }
        self.capture.appendSse(bytes) catch |err| {
            if (self.capture.resource_exceeded) {
                self.recordDisposition(.capture_resource_exceeded);
            } else {
                self.recordDisposition(.{ .host_error = err });
            }
            return 0;
        };
        if (self.capture.terminalObserved()) {
            self.recordDisposition(.terminal_observed);
            return 0;
        }
        return length;
    }

    fn headerCallback(
        pointer: [*]u8,
        size: usize,
        count: usize,
        userdata: ?*anyopaque,
    ) callconv(.c) usize {
        const self: *EasyTransfer = @ptrCast(@alignCast(userdata orelse return 0));
        const length = std.math.mul(usize, size, count) catch return 0;
        const line = pointer[0..length];
        if (std.mem.startsWith(u8, line, "HTTP/")) {
            const first_space = std.mem.indexOfScalar(u8, line, ' ') orelse return 0;
            const status_end = std.mem.indexOfScalarPos(u8, line, first_space + 1, ' ') orelse
                std.mem.indexOfScalarPos(u8, line, first_space + 1, '\r') orelse return 0;
            self.status = std.fmt.parseInt(u16, line[first_space + 1 .. status_end], 10) catch return 0;
            self.encoding_is_identity = true;
            self.diagnostic_length = 0;
            self.diagnostic_overflowed = false;
            return length;
        }
        const name = "content-encoding:";
        if (line.len >= name.len and std.ascii.eqlIgnoreCase(line[0..name.len], name)) {
            const value = std.mem.trim(u8, line[name.len..], " \t\r\n");
            self.encoding_is_identity = value.len == 0 or std.ascii.eqlIgnoreCase(value, "identity");
        }
        return length;
    }

    fn progressCallback(
        userdata: ?*anyopaque,
        _: c.curl_off_t,
        _: c.curl_off_t,
        _: c.curl_off_t,
        _: c.curl_off_t,
    ) callconv(.c) c_int {
        const self: *EasyTransfer = @ptrCast(@alignCast(userdata orelse return 1));
        std.Io.checkCancel(self.io) catch {
            self.recordDisposition(.cancelled);
            return 1;
        };
        return 0;
    }

    /// libcurl can invoke a progress callback after another callback has
    /// already decided the OnePage outcome. Preserve the callback that first
    /// crossed the semantic boundary; CURLcode only explains why libcurl
    /// returned after that decision.
    fn recordDisposition(
        self: *EasyTransfer,
        disposition: CallbackDisposition,
    ) void {
        switch (self.disposition) {
            .none => {},
            else => return,
        }
        self.disposition = disposition;
    }

    fn appendDiagnostic(self: *EasyTransfer, bytes: []const u8) void {
        if (self.diagnostic_overflowed) return;
        if (bytes.len > diagnostic_body_limit -| self.diagnostic_length) {
            self.diagnostic_overflowed = true;
            self.diagnostic_length = 0;
            return;
        }
        @memcpy(self.diagnostic[self.diagnostic_length..][0..bytes.len], bytes);
        self.diagnostic_length += bytes.len;
    }

    fn result(self: *EasyTransfer, code: c.CURLcode) !codex_provider.TransportResult {
        switch (self.disposition) {
            .terminal_observed, .capture_resource_exceeded => return .{ .disposition = .complete },
            else => {},
        }
        if (self.status != 0 and (self.status < 200 or self.status >= 300)) {
            var transport_result: codex_provider.TransportResult = .{ .disposition = .provider_rejected };
            try transport_result.setHttpStatus(self.status);
            if (!self.diagnostic_overflowed and code == c.CURLE_OK) {
                setProviderFailureCode(self.diagnostic[0..self.diagnostic_length], &transport_result);
            }
            transport_result.disposition = classifyHttpFailure(
                self.status,
                transport_result.diagnosticCode(),
            );
            return transport_result;
        }
        switch (self.disposition) {
            .invalid_encoding => return .{ .disposition = .invalid_encoding },
            .cancelled => return .{ .disposition = .cancelled },
            .host_error => |err| return err,
            .none => {},
            .terminal_observed, .capture_resource_exceeded => unreachable,
        }
        if (code == c.CURLE_OPERATION_TIMEDOUT) return .{ .disposition = .timed_out };
        if (code == c.CURLE_OK) return .{ .disposition = .complete };
        return .{ .disposition = if (self.upload_bytes == 0) .not_started else .may_have_started };
    }
};

test "model transport keeps the first callback disposition" {
    var terminal_first: EasyTransfer = undefined;
    terminal_first.disposition = .none;
    terminal_first.recordDisposition(.terminal_observed);
    terminal_first.recordDisposition(.cancelled);
    try std.testing.expect(terminal_first.disposition == .terminal_observed);

    var cancel_first: EasyTransfer = undefined;
    cancel_first.disposition = .none;
    cancel_first.recordDisposition(.cancelled);
    cancel_first.recordDisposition(.{ .host_error = error.MalformedSseFrame });
    try std.testing.expect(cancel_first.disposition == .cancelled);

    var host_failure_first: EasyTransfer = undefined;
    host_failure_first.disposition = .none;
    host_failure_first.recordDisposition(.{ .host_error = error.InjectedHostReadFailure });
    host_failure_first.recordDisposition(.terminal_observed);
    switch (host_failure_first.disposition) {
        .host_error => |err| try std.testing.expect(err == error.InjectedHostReadFailure),
        else => return error.ExpectedHostReadFailure,
    }
}

test "model transport classifies pre-upload and post-upload failures" {
    var transfer: EasyTransfer = undefined;
    transfer.status = 0;
    transfer.disposition = .none;
    transfer.upload_bytes = 0;
    try std.testing.expectEqual(
        codex_provider.TransportDisposition.not_started,
        (try transfer.result(c.CURLE_COULDNT_CONNECT)).disposition,
    );

    transfer.upload_bytes = 1;
    try std.testing.expectEqual(
        codex_provider.TransportDisposition.may_have_started,
        (try transfer.result(c.CURLE_RECV_ERROR)).disposition,
    );

    transfer.upload_bytes = 0;
    try std.testing.expectEqual(
        codex_provider.TransportDisposition.timed_out,
        (try transfer.result(c.CURLE_OPERATION_TIMEDOUT)).disposition,
    );
}

fn appendCurlHeader(
    list: ?*c.struct_curl_slist,
    header: [*:0]const u8,
) !?*c.struct_curl_slist {
    return c.curl_slist_append(list, header) orelse error.CurlHeaderAllocationFailed;
}

fn setCurlOption(easy: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(easy, option, value) != c.CURLE_OK) return error.CurlOptionFailed;
}

fn durationMilliseconds(duration: std.Io.Duration) c_long {
    return @intCast(@max(@as(i64, 1), duration.toMilliseconds()));
}

const RequestControl = struct {
    const Winner = enum { running, terminal, timed_out };
    mutex: std.Io.Mutex = .init,
    stream: ?std.Io.net.Stream = null,
    winner: Winner = .running,

    fn publish(self: *RequestControl, io: std.Io, stream: std.Io.net.Stream) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.stream = stream;
        if (self.winner == .timed_out) interruptStream(io, stream);
    }

    fn clear(self: *RequestControl, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.stream = null;
    }

    fn interrupt(self: *RequestControl, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.winner != .running) return;
        self.winner = .timed_out;
        if (self.stream) |stream| interruptStream(io, stream);
    }

    fn observeTerminal(
        self: *RequestControl,
        io: std.Io,
        result: codex_provider.TransportResult,
        completed_result: *?codex_provider.TransportResult,
    ) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.winner == .timed_out) return;
        self.winner = .terminal;
        completed_result.* = result;
    }

    fn observeComplete(self: *RequestControl, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.winner == .running) self.winner = .terminal;
    }

    fn winnerValue(self: *RequestControl, io: std.Io) Winner {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.winner;
    }

    fn terminalResult(
        self: *RequestControl,
        io: std.Io,
        completed_result: *const ?codex_provider.TransportResult,
    ) ?codex_provider.TransportResult {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return completed_result.*;
    }
};

fn interruptStream(io: std.Io, stream: std.Io.net.Stream) void {
    // The request still owns and closes the socket. A shutdown error means the
    // socket is already terminal, so cleanup can join the request without a
    // competing close or a detached task.
    stream.shutdown(io, .both) catch {};
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
    if (status == 400 and std.mem.eql(u8, code, "model_not_supported")) {
        return .model_not_found;
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

fn setProviderFailureCode(body: []const u8, result: *codex_provider.TransportResult) void {
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
    const error_value = outer.get("error") orelse {
        setUnsupportedModelDetail(&outer, result);
        return;
    };
    const error_object = switch (error_value) {
        .object => |value| value,
        else => return,
    };
    const code_value = error_object.get("code") orelse error_object.get("type") orelse return;
    const code = switch (code_value) {
        .string => |value| value,
        else => return,
    };
    result.setDiagnosticCode(code) catch {};
}

fn setUnsupportedModelDetail(
    outer: *const std.json.ObjectMap,
    result: *codex_provider.TransportResult,
) void {
    if (outer.count() != 1) return;
    const detail_value = outer.get("detail") orelse return;
    const detail = switch (detail_value) {
        .string => |value| value,
        else => return,
    };
    const prefix = "The '";
    const suffix = "' model is not supported when using Codex with a ChatGPT account.";
    if (!std.mem.startsWith(u8, detail, prefix) or !std.mem.endsWith(u8, detail, suffix)) return;
    const model = detail[prefix.len .. detail.len - suffix.len];
    if (model.len == 0 or model.len > session_store.model_name_capacity) return;
    for (model) |byte| if (!std.ascii.isAlphanumeric(byte) and
        byte != '-' and byte != '_' and byte != '.' and byte != ':' and byte != '/')
    {
        return;
    };
    result.setDiagnosticCode("model_not_supported") catch {};
}

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

test "authorization header admits the exact credential bound" {
    var token: [codex_auth.max_token_size]u8 = @splat('a');
    defer std.crypto.secureZero(u8, &token);
    var header: [authorization_header_capacity]u8 = undefined;
    defer std.crypto.secureZero(u8, &header);
    const encoded = try std.fmt.bufPrintZ(
        &header,
        authorization_header_prefix ++ "{s}",
        .{&token},
    );
    try std.testing.expectEqual(
        authorization_header_prefix.len + codex_auth.max_token_size,
        encoded.len,
    );
}

test "HTTP diagnostics retain only bounded provider error code or type" {
    var result: codex_provider.TransportResult = .{ .disposition = .provider_rejected };
    setProviderFailureCode(
        "{\"error\":{\"code\":\"originator_not_allowed\",\"message\":\"unbounded secret-adjacent text\"}}",
        &result,
    );
    try std.testing.expectEqualStrings("originator_not_allowed", result.diagnosticCode());

    setProviderFailureCode("{\"error\":{\"type\":\"invalid_request_error\"}}", &result);
    try std.testing.expectEqualStrings("invalid_request_error", result.diagnosticCode());

    setProviderFailureCode("{\"error\":{\"code\":\"not a bounded code\"}}", &result);
    try std.testing.expectEqualStrings("invalid_request_error", result.diagnosticCode());
}

test "authorization HTTP primitive deadlines and joins every OAuth call class" {
    const io = std.testing.io;
    const Call = enum { request_device, poll_device, exchange, refresh, revoke };
    const calls = [_]Call{ .request_device, .poll_device, .exchange, .refresh, .revoke };
    for (calls) |call| {
        var fixture = try WireFixture.init(io, .ok, "{}", .stall);
        defer fixture.deinit(io);
        var server_future = io.async(WireFixture.serve, .{ &fixture, io });
        var endpoint_buffer: [128]u8 = undefined;
        const endpoint = try fixture.endpoint(&endpoint_buffer);
        const path_start = std.mem.indexOf(u8, endpoint, "/backend-api/") orelse unreachable;
        var http: NativeHttp = .{
            .io = io,
            .allocator = std.testing.allocator,
            .timeout = std.Io.Duration.fromMilliseconds(50),
            .authorization_origin_override = endpoint[0..path_start],
        };
        var device: codex_auth.DeviceCode = .{
            .device_id_length = 6,
            .user_code_length = 4,
            .interval_seconds = 1,
        };
        @memcpy(device.device_id[0..6], "device");
        @memcpy(device.user_code[0..4], "code");
        var authorization: codex_auth.AuthorizationCode = .{
            .code_length = 4,
            .verifier_length = 8,
        };
        @memcpy(authorization.code[0..4], "code");
        @memcpy(authorization.verifier[0..8], "verifier");
        var tokens: codex_auth.Tokens = .{
            .access_length = 6,
            .refresh_length = 7,
            .account_length = 7,
        };
        defer tokens.scrub();
        @memcpy(tokens.access[0..6], "access");
        @memcpy(tokens.refresh[0..7], "refresh");
        @memcpy(tokens.account[0..7], "account");
        const started = std.Io.Clock.awake.now(io);
        switch (call) {
            .request_device => try std.testing.expectError(
                error.HttpRequestTimedOut,
                codex_auth.requestDeviceCode(http.capability()),
            ),
            .poll_device => try std.testing.expectError(
                error.HttpRequestTimedOut,
                codex_auth.pollDeviceCode(http.capability(), &device),
            ),
            .exchange => try std.testing.expectError(
                error.HttpRequestTimedOut,
                codex_auth.exchangeCode(http.capability(), &authorization),
            ),
            .refresh => try std.testing.expectError(
                error.HttpRequestTimedOut,
                codex_auth.refresh(http.capability(), &tokens),
            ),
            .revoke => try std.testing.expectError(
                error.HttpRequestTimedOut,
                codex_auth.revoke(http.capability(), &tokens),
            ),
        }
        const elapsed = started.durationTo(std.Io.Clock.awake.now(io));
        try server_future.await(io);
        try std.testing.expect(elapsed.nanoseconds < std.Io.Duration.fromMilliseconds(500).nanoseconds);
        try std.testing.expect(fixture.peer_closed);
        try std.testing.expectEqual(std.http.Method.POST, fixture.method);
        try std.testing.expect(fixture.accept_encoding_identity);
    }
}

test "authorization request rejects compressed response bytes before JSON decoding" {
    const io = std.testing.io;
    var fixture = try WireFixture.init(io, .ok, "not actually compressed", .complete);
    fixture.response_encoding = "gzip";
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });
    defer {
        const server_result = server_future.cancel(io);
        server_result catch |err| std.debug.assert(err == error.Canceled);
    }
    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try fixture.endpoint(&endpoint_buffer);
    var http: NativeHttp = .{
        .io = io,
        .allocator = std.testing.allocator,
    };
    var response_bytes: [codex_auth.max_response_size]u8 = undefined;
    var request_control: RequestControl = .{};
    var completed_response: ?codex_auth.HttpResponse = null;
    try std.testing.expectError(
        error.UnexpectedContentEncoding,
        http.postRequest(
            endpoint,
            "application/json",
            "{}",
            &response_bytes,
            &request_control,
            &completed_response,
        ),
    );
    try server_future.await(io);
    try std.testing.expect(fixture.accept_encoding_identity);
}

test "authorization classifies compressed refresh rejection from status" {
    const io = std.testing.io;
    var fixture = try WireFixture.init(io, .unauthorized, "not actually compressed", .complete);
    fixture.response_encoding = "gzip";
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });
    defer {
        const server_result = server_future.cancel(io);
        server_result catch |err| std.debug.assert(err == error.Canceled);
    }
    var endpoint_buffer: [128]u8 = undefined;
    const endpoint = try fixture.endpoint(&endpoint_buffer);
    const path_start = std.mem.indexOf(u8, endpoint, "/backend-api/") orelse unreachable;
    var http: NativeHttp = .{
        .io = io,
        .allocator = std.testing.allocator,
        .timeout = std.Io.Duration.fromSeconds(1),
        .authorization_origin_override = endpoint[0..path_start],
    };
    var tokens: codex_auth.Tokens = .{ .refresh_length = "refresh".len };
    defer tokens.scrub();
    @memcpy(tokens.refresh[0.."refresh".len], "refresh");
    try std.testing.expectError(error.RefreshRejected, codex_auth.refresh(http.capability(), &tokens));
    try server_future.await(io);
    try std.testing.expect(fixture.accept_encoding_identity);
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
    var fixture = try WireFixture.init(io, .ok, response, .keep_open);
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });

    var endpoint_buffer: [128]u8 = undefined;
    const local_endpoint = try fixture.endpoint(&endpoint_buffer);
    var transport: NativeTransport = .{
        .io = io,
        .endpoint = local_endpoint,
        .timeout = std.Io.Duration.fromSeconds(1),
    };
    var credential = fakeCredential();
    defer credential.scrub();
    var capture = codex_provider.Capture.init(
        std.testing.allocator,
        provider_io.candidateCapability(),
    );
    defer capture.deinit();
    const capability = transport.capability();
    const disposition = capability.perform_fn(
        capability.context,
        &credential,
        try provider_io.request(),
        &capture,
    );
    const server_result = server_future.cancel(io);
    server_result catch |err| if (err != error.Canceled) return err;

    try std.testing.expectEqual(codex_provider.TransportDisposition.complete, (try disposition).disposition);
    try std.testing.expect(capture.terminalObserved());
    try fixture.expectProductionRequest(false);
}

test "NativeTransport rejects compressed response bytes before SSE capture" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1025, 1, 1);
    var provider_io = try model_operation.ProviderIo.open(&wire.session, 1025, 1026);
    defer provider_io.close();

    var fixture = try WireFixture.init(io, .ok, "not actually compressed", .complete);
    fixture.response_encoding = "gzip";
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });
    var endpoint_buffer: [128]u8 = undefined;
    var transport: NativeTransport = .{
        .io = io,
        .endpoint = try fixture.endpoint(&endpoint_buffer),
    };
    var credential = fakeCredential();
    defer credential.scrub();
    var capture = codex_provider.Capture.init(
        std.testing.allocator,
        provider_io.candidateCapability(),
    );
    defer capture.deinit();
    const capability = transport.capability();
    const result = try capability.perform_fn(
        capability.context,
        &credential,
        try provider_io.request(),
        &capture,
    );
    try server_future.await(io);
    try std.testing.expectEqual(codex_provider.TransportDisposition.invalid_encoding, result.disposition);
    try std.testing.expect(!capture.terminalObserved());
    try std.testing.expect(fixture.accept_encoding_identity);
}

test "NativeTransport classifies compressed HTTP rejection from status" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1030, 1, 1);
    var provider_io = try model_operation.ProviderIo.open(&wire.session, 1030, 1031);
    defer provider_io.close();

    var fixture = try WireFixture.init(io, .unauthorized, "not actually compressed", .complete);
    fixture.response_encoding = "gzip";
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });
    var endpoint_buffer: [128]u8 = undefined;
    var transport: NativeTransport = .{
        .io = io,
        .endpoint = try fixture.endpoint(&endpoint_buffer),
    };
    var credential = fakeCredential();
    defer credential.scrub();
    var capture = codex_provider.Capture.init(
        std.testing.allocator,
        provider_io.candidateCapability(),
    );
    defer capture.deinit();
    const capability = transport.capability();
    const result = try capability.perform_fn(
        capability.context,
        &credential,
        try provider_io.request(),
        &capture,
    );
    try server_future.await(io);
    try std.testing.expectEqual(codex_provider.TransportDisposition.http_unauthorized, result.disposition);
    try std.testing.expectEqual(@as(?u16, 401), result.httpStatus());
    try std.testing.expectEqualStrings("", result.diagnosticCode());
    try std.testing.expect(!capture.terminalObserved());
    try std.testing.expect(fixture.accept_encoding_identity);
}

test "NativeTransport distinguishes failure before and after upload" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1040, 1, 1);

    var closed_fixture = try WireFixture.init(io, .ok, "", .complete);
    var closed_endpoint_buffer: [128]u8 = undefined;
    const closed_endpoint_value = try closed_fixture.endpoint(&closed_endpoint_buffer);
    var closed_endpoint: [128]u8 = undefined;
    @memcpy(closed_endpoint[0..closed_endpoint_value.len], closed_endpoint_value);
    closed_fixture.deinit(io);
    var before_io = try model_operation.ProviderIo.open(&wire.session, 1040, 1041);
    defer before_io.close();
    var before_capture = codex_provider.Capture.init(std.testing.allocator, null);
    defer before_capture.deinit();
    var credential = fakeCredential();
    defer credential.scrub();
    var before_transport: NativeTransport = .{
        .io = io,
        .endpoint = closed_endpoint[0..closed_endpoint_value.len],
    };
    const before = try before_transport.capability().perform_fn(
        &before_transport,
        &credential,
        try before_io.request(),
        &before_capture,
    );
    try std.testing.expectEqual(codex_provider.TransportDisposition.not_started, before.disposition);
    before_io.close();

    var after_io = try model_operation.ProviderIo.open(&wire.session, 1040, 1042);
    defer after_io.close();
    var after_fixture = try WireFixture.init(io, .ok, "", .close_after_request);
    defer after_fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &after_fixture, io });
    var after_endpoint_buffer: [128]u8 = undefined;
    var after_transport: NativeTransport = .{
        .io = io,
        .endpoint = try after_fixture.endpoint(&after_endpoint_buffer),
    };
    var after_capture = codex_provider.Capture.init(std.testing.allocator, null);
    defer after_capture.deinit();
    const after = try after_transport.capability().perform_fn(
        &after_transport,
        &credential,
        try after_io.request(),
        &after_capture,
    );
    try server_future.await(io);
    try std.testing.expectEqual(codex_provider.TransportDisposition.may_have_started, after.disposition);
    try std.testing.expect(after_fixture.body_length != 0);
}

test "NativeTransport preserves malformed capture and Host read failures" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1045, 1, 1);
    var credential = fakeCredential();
    defer credential.scrub();

    var malformed_io = try model_operation.ProviderIo.open(&wire.session, 1045, 1046);
    defer malformed_io.close();
    const malformed_response =
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"bad\\x\"}]}}\n\n" ++
        "data: {\"type\":\"response.completed\"}\n\n";
    var fixture = try WireFixture.init(io, .ok, malformed_response, .complete);
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });
    var endpoint_buffer: [128]u8 = undefined;
    var transport: NativeTransport = .{
        .io = io,
        .endpoint = try fixture.endpoint(&endpoint_buffer),
    };
    var malformed_capture = codex_provider.Capture.init(std.testing.allocator, null);
    defer malformed_capture.deinit();
    const malformed_result = try transport.capability().perform_fn(
        &transport,
        &credential,
        try malformed_io.request(),
        &malformed_capture,
    );
    try server_future.await(io);
    try std.testing.expectEqual(codex_provider.TransportDisposition.complete, malformed_result.disposition);
    try std.testing.expect(malformed_capture.malformed);
    malformed_io.close();

    var closed_io = try model_operation.ProviderIo.open(&wire.session, 1045, 1047);
    const closed_request = try closed_io.request();
    closed_io.close();
    wire.session.close();
    var closed_capture = codex_provider.Capture.init(std.testing.allocator, null);
    defer closed_capture.deinit();
    try std.testing.expectError(
        error.SessionClosed,
        transport.capability().perform_fn(
            &transport,
            &credential,
            closed_request,
            &closed_capture,
        ),
    );
}

test "NativeTransport timeout bounds the entire call and closes an open response body" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1050, 1, 1);
    const cases = [_]struct {
        status: std.http.Status,
        body: []const u8,
        expected: codex_provider.TransportDisposition,
        expected_status: ?u16,
    }{
        .{
            .status = .ok,
            .body = "data: {\"type\":\"response.created\"}\n\n",
            .expected = .timed_out,
            .expected_status = null,
        },
        .{
            .status = .bad_request,
            .body = "{\"error\":{\"code\":\"incomplete",
            .expected = .provider_rejected,
            .expected_status = 400,
        },
    };
    for (cases, 0..) |case, index| {
        var provider_io = try model_operation.ProviderIo.open(&wire.session, 1050, 1051 + index);
        defer provider_io.close();
        var fixture = try WireFixture.init(io, case.status, case.body, .stall);
        defer fixture.deinit(io);
        var server_future = io.async(WireFixture.serve, .{ &fixture, io });
        var endpoint_buffer: [128]u8 = undefined;
        var transport: NativeTransport = .{
            .io = io,
            .endpoint = try fixture.endpoint(&endpoint_buffer),
            .timeout = std.Io.Duration.fromMilliseconds(50),
        };
        var credential = fakeCredential();
        defer credential.scrub();
        var capture = codex_provider.Capture.init(std.testing.allocator, null);
        defer capture.deinit();

        const started = std.Io.Clock.awake.now(io);
        const capability = transport.capability();
        const disposition = try capability.perform_fn(
            capability.context,
            &credential,
            try provider_io.request(),
            &capture,
        );
        const elapsed = started.durationTo(std.Io.Clock.awake.now(io));
        try server_future.await(io);

        try std.testing.expectEqual(case.expected, disposition.disposition);
        try std.testing.expectEqual(case.expected_status, disposition.httpStatus());
        try std.testing.expectEqualStrings("", disposition.diagnosticCode());
        try std.testing.expect(elapsed.nanoseconds < std.Io.Duration.fromMilliseconds(500).nanoseconds);
        try std.testing.expect(fixture.peer_closed);
    }
}

test "NativeTransport cancellation returns a typed result and joins the easy transfer" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1075, 1, 1);
    var provider_io = try model_operation.ProviderIo.open(&wire.session, 1075, 1076);
    defer provider_io.close();

    var fixture = try WireFixture.init(
        io,
        .ok,
        "data: {\"type\":\"response.created\"}\n\n",
        .stall,
    );
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });
    var endpoint_buffer: [128]u8 = undefined;
    var transport: NativeTransport = .{
        .io = io,
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .timeout = std.Io.Duration.fromSeconds(10),
    };
    var credential = fakeCredential();
    defer credential.scrub();
    var capture = codex_provider.Capture.init(std.testing.allocator, null);
    defer capture.deinit();
    const capability = transport.capability();
    var request_future = io.async(NativeTransport.perform, .{
        capability.context,
        &credential,
        try provider_io.request(),
        &capture,
    });
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake);

    const started = std.Io.Clock.awake.now(io);
    const result = try request_future.cancel(io);
    const elapsed = started.durationTo(std.Io.Clock.awake.now(io));
    try server_future.await(io);

    try std.testing.expectEqual(codex_provider.TransportDisposition.cancelled, result.disposition);
    try std.testing.expect(elapsed.nanoseconds < std.Io.Duration.fromMilliseconds(1500).nanoseconds);
    try std.testing.expect(fixture.peer_closed);
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
    try wire.session.storeContent(1100, call_bytes);
    const call = try wire.session.appendConversationForTest(.tool_call, 1100, null);
    try commitConversation(&wire.session, call);
    var result_buffer: [256]u8 = undefined;
    const result_bytes = try conversation.encodeToolResult(&result_buffer, .{
        .parent_id = call.entry_id,
        .is_error = false,
        .content = "exit_code=0",
    });
    try wire.session.storeContent(1101, result_bytes);
    const result = try wire.session.appendConversationForTest(.tool_result, 1101, null);
    try commitConversation(&wire.session, result);
    _ = try model_operation.buildRequest(&wire.session, 1102, 1, 3);
    var provider_io = try model_operation.ProviderIo.open(&wire.session, 1102, 1103);
    defer provider_io.close();

    const response =
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"verified\"}]}}\n\n" ++
        "data: {\"type\":\"response.done\",\"response\":{\"status\":\"completed\"}}\n\n";
    var fixture = try WireFixture.init(io, .ok, response, .complete);
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });
    var endpoint_buffer: [128]u8 = undefined;
    var transport: NativeTransport = .{
        .io = io,
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .timeout = std.Io.Duration.fromSeconds(1),
    };
    var credential = fakeCredential();
    defer credential.scrub();
    var capture = codex_provider.Capture.init(
        std.testing.allocator,
        provider_io.candidateCapability(),
    );
    defer capture.deinit();
    const capability = transport.capability();
    const disposition = try capability.perform_fn(
        capability.context,
        &credential,
        try provider_io.request(),
        &capture,
    );
    try server_future.await(io);
    try std.testing.expectEqual(codex_provider.TransportDisposition.complete, disposition.disposition);
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
        var fixture = try WireFixture.init(io, case.status, body, .complete);
        defer fixture.deinit(io);
        var server_future = io.async(WireFixture.serve, .{ &fixture, io });
        var endpoint_buffer: [128]u8 = undefined;
        var transport: NativeTransport = .{
            .io = io,
            .endpoint = try fixture.endpoint(&endpoint_buffer),
            .timeout = std.Io.Duration.fromSeconds(1),
        };
        var credential = fakeCredential();
        defer credential.scrub();
        var capture = codex_provider.Capture.init(std.testing.allocator, null);
        defer capture.deinit();
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
        try std.testing.expectEqual(case.expected, disposition.disposition);
        try std.testing.expectEqual(@as(?u16, @intFromEnum(case.status)), disposition.httpStatus());
        try std.testing.expectEqualStrings(case.code, disposition.diagnosticCode());
    }
}

test "NativeTransport reads a chunked provider diagnostic after the response head" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1300, 1, 1);
    var provider_io = try model_operation.ProviderIo.open(&wire.session, 1300, 1301);
    defer provider_io.close();

    const body = "{\"error\":{\"code\":\"unsupported_parameter\",\"message\":\"discard this message\"}}";
    var fixture = try WireFixture.init(io, .bad_request, body, .chunked);
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });
    var endpoint_buffer: [128]u8 = undefined;
    var transport: NativeTransport = .{
        .io = io,
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .timeout = std.Io.Duration.fromSeconds(1),
    };
    var credential = fakeCredential();
    defer credential.scrub();
    var capture = codex_provider.Capture.init(std.testing.allocator, null);
    defer capture.deinit();
    const capability = transport.capability();
    const disposition = try capability.perform_fn(
        capability.context,
        &credential,
        try provider_io.request(),
        &capture,
    );
    try server_future.await(io);
    try std.testing.expectEqual(codex_provider.TransportDisposition.provider_rejected, disposition.disposition);
    try std.testing.expectEqual(@as(?u16, 400), disposition.httpStatus());
    try std.testing.expectEqualStrings("unsupported_parameter", disposition.diagnosticCode());
}

test "NativeTransport classifies the bounded ChatGPT unsupported-model detail" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1350, 1, 1);
    try expectUnsupportedModelWireCase(
        io,
        &wire.session,
        1350,
        1351,
        "{\"detail\":\"The 'gpt-5.3-codex' model is not supported when using Codex with a ChatGPT account.\"}",
        .model_not_found,
        "model_not_supported",
    );

    const rejected = [_][]const u8{
        "{\"detail\":\"This model is unavailable.\"}",
        "{\"detail\":42}",
        "{\"detail\":\"The 'gpt-5.3\\ncodex' model is not supported when using Codex with a ChatGPT account.\"}",
        "{\"detail\":\"The 'gpt-5.3-codex' model is not supported when using Codex with a ChatGPT account.\",\"extra\":true}",
    };
    for (rejected, 0..) |body, index| try expectUnsupportedModelWireCase(
        io,
        &wire.session,
        1350,
        1352 + index,
        body,
        .provider_rejected,
        "",
    );

    const oversized_model: [session_store.model_name_capacity + 1]u8 = @splat('m');
    var body_buffer: [512]u8 = undefined;
    const oversized_body = try std.fmt.bufPrint(
        &body_buffer,
        "{{\"detail\":\"The '{s}' model is not supported when using Codex with a ChatGPT account.\"}}",
        .{&oversized_model},
    );
    try expectUnsupportedModelWireCase(
        io,
        &wire.session,
        1350,
        1356,
        oversized_body,
        .provider_rejected,
        "",
    );
}

fn expectUnsupportedModelWireCase(
    io: std.Io,
    session: *session_store.Session,
    operation_id: u64,
    response_id: u64,
    body: []const u8,
    expected: codex_provider.TransportDisposition,
    expected_code: []const u8,
) !void {
    var provider_io = try model_operation.ProviderIo.open(session, operation_id, response_id);
    defer provider_io.close();
    var fixture = try WireFixture.init(io, .bad_request, body, .complete);
    defer fixture.deinit(io);
    var server_future = io.async(WireFixture.serve, .{ &fixture, io });
    var endpoint_buffer: [128]u8 = undefined;
    var transport: NativeTransport = .{
        .io = io,
        .endpoint = try fixture.endpoint(&endpoint_buffer),
        .timeout = std.Io.Duration.fromSeconds(1),
    };
    var credential = fakeCredential();
    defer credential.scrub();
    var capture = codex_provider.Capture.init(std.testing.allocator, null);
    defer capture.deinit();
    const capability = transport.capability();
    const disposition = try capability.perform_fn(
        capability.context,
        &credential,
        try provider_io.request(),
        &capture,
    );
    try server_future.await(io);
    try std.testing.expectEqual(expected, disposition.disposition);
    try std.testing.expectEqual(@as(?u16, 400), disposition.httpStatus());
    try std.testing.expectEqualStrings(expected_code, disposition.diagnosticCode());
}

test "NativeTransport keeps status without retaining oversized or malformed provider bodies" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var wire = try WireSession.init(io, &tmp);
    defer wire.deinit(io);
    _ = try model_operation.buildRequest(&wire.session, 1400, 1, 1);

    var oversized: [4097]u8 = @splat('x');
    const cases = [_]struct {
        body: []const u8,
        mode: WireFixture.ResponseMode,
    }{
        .{ .body = &oversized, .mode = .chunked },
        .{ .body = "{not-json}", .mode = .chunked },
        .{ .body = "{\"error\":{\"code\":\"incomplete\"}}", .mode = .keep_open },
    };
    for (cases, 0..) |case, index| {
        var fixture = try WireFixture.init(io, .bad_request, case.body, case.mode);
        defer fixture.deinit(io);
        var server_future = io.async(WireFixture.serve, .{ &fixture, io });
        var endpoint_buffer: [128]u8 = undefined;
        var transport: NativeTransport = .{
            .io = io,
            .endpoint = try fixture.endpoint(&endpoint_buffer),
            .timeout = std.Io.Duration.fromSeconds(1),
        };
        var credential = fakeCredential();
        defer credential.scrub();
        var capture = codex_provider.Capture.init(std.testing.allocator, null);
        defer capture.deinit();
        var provider_io = try model_operation.ProviderIo.open(
            &wire.session,
            1400,
            1401 + index,
        );
        defer provider_io.close();
        const capability = transport.capability();
        const disposition = try capability.perform_fn(
            capability.context,
            &credential,
            try provider_io.request(),
            &capture,
        );
        const server_result = server_future.cancel(io);
        server_result catch |err| if (err != error.Canceled) return err;
        try std.testing.expectEqual(codex_provider.TransportDisposition.provider_rejected, disposition.disposition);
        try std.testing.expectEqual(@as(?u16, 400), disposition.httpStatus());
        try std.testing.expectEqualStrings("", disposition.diagnosticCode());
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
    scratch: *session_store.TransientScratch,
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
        const scratch = try session_store.allocateTransientScratch(std.testing.allocator);
        errdefer session_store.destroyTransientScratch(std.testing.allocator, io, scratch);
        var path_buffer: [128]u8 = undefined;
        const workspace_path = try std.fmt.bufPrint(
            &path_buffer,
            ".zig-cache/tmp/{s}/repo",
            .{tmp.sub_path},
        );
        const session = try session_store.Session.create(sessions, scratch, storage, io, .{
            .workspace_path = workspace_path,
            .model = "codex:gpt-5.1-codex-mini",
            .task = "Inspect the repository",
        });
        return .{ .storage = storage, .scratch = scratch, .sessions = sessions, .session = session };
    }

    fn deinit(self: *WireSession, io: std.Io) void {
        self.session.close();
        session_store.destroyTransientScratch(std.testing.allocator, io, self.scratch);
        self.storage.close();
        std.testing.allocator.destroy(self.storage);
        self.sessions.close(io);
    }
};

fn commitConversation(session: *session_store.Session, entry: session_store.ConversationEntry) !void {
    _ = try session.commitFactsForTest(&.{session_transition.conversationAdvanced(.{
        .agent = .{
            .agent_id = session.agent_id,
            .agent_generation = 1,
            .ownership_epoch = session.ownership_epoch,
        },
        .entry_id = entry.entry_id,
        .parent_id = entry.parent_id,
        .kind = entry.kind,
        .content_ref = entry.content_ref,
    })});
}

const WireFixture = struct {
    const ResponseMode = enum { complete, keep_open, stall, chunked, close_after_request };

    listener: std.Io.net.Server,
    status: std.http.Status,
    response: []const u8,
    response_mode: ResponseMode,
    response_encoding: []const u8 = "identity",
    method: std.http.Method = .GET,
    target: [128]u8 = @splat(0),
    target_length: usize = 0,
    authorization: bool = false,
    account: bool = false,
    originator: bool = false,
    accept: bool = false,
    content_type: bool = false,
    beta: bool = false,
    accept_encoding_identity: bool = false,
    body: [96 * 1024]u8 = undefined,
    body_length: usize = 0,
    peer_closed: bool = false,

    fn init(io: std.Io, status: std.http.Status, response: []const u8, response_mode: ResponseMode) !WireFixture {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        return .{
            .listener = try address.listen(io, .{}),
            .status = status,
            .response = response,
            .response_mode = response_mode,
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
            } else if (std.ascii.eqlIgnoreCase(header.name, "accept-encoding")) {
                self.accept_encoding_identity = std.mem.eql(u8, header.value, "identity");
            }
        }
        const body_length = request.head.content_length orelse return error.MissingContentLength;
        if (body_length > self.body.len) return error.RequestBodyTooLarge;
        const body_reader = try request.readerExpectContinue(&.{});
        try body_reader.readSliceAll(self.body[0..@intCast(body_length)]);
        self.body_length = @intCast(body_length);
        if (self.response_mode == .close_after_request) return;
        const response_headers = [_]std.http.Header{
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "content-encoding", .value = self.response_encoding },
        };
        if (self.response_mode == .complete) {
            try request.respond(self.response, .{
                .status = self.status,
                .extra_headers = &response_headers,
            });
            return;
        }
        var response_buffer: [4096]u8 = undefined;
        var response_writer = try request.respondStreaming(&response_buffer, .{
            .content_length = if (self.response_mode == .keep_open or self.response_mode == .stall)
                self.response.len + 1
            else
                null,
            .respond_options = .{
                .status = self.status,
                .extra_headers = &response_headers,
            },
        });
        try response_writer.writer.writeAll(self.response);
        try response_writer.writer.flush();
        try response_writer.flush();
        if (self.response_mode == .chunked) {
            try response_writer.end();
            return;
        }
        if (self.response_mode == .stall) {
            const PeerResult = union(enum) { closed: bool, guard };
            var results: [2]PeerResult = undefined;
            var select = std.Io.Select(PeerResult).init(io, &results);
            select.async(.closed, waitForPeerClose, .{&stream_reader.interface});
            select.async(.guard, interruptPeerAfterGuard, .{ io, &stream });
            const selected = try select.await();
            select.cancelDiscard();
            self.peer_closed = switch (selected) {
                .closed => |closed| closed,
                .guard => false,
            };
            return;
        }
        try std.Io.sleep(io, std.Io.Duration.fromSeconds(5), .awake);
    }

    fn waitForPeerClose(reader: *std.Io.Reader) bool {
        _ = reader.peekGreedy(1) catch |err| return err == error.EndOfStream;
        return false;
    }

    fn interruptPeerAfterGuard(io: std.Io, stream: *const std.Io.net.Stream) void {
        std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .awake) catch return;
        stream.shutdown(io, .both) catch {};
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
        try std.testing.expect(self.accept_encoding_identity);
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
        const tools = object.get("tools").?.array;
        try std.testing.expectEqual(model_contract.default_catalog.len, tools.items.len);
        for (tools.items, model_contract.default_catalog) |tool, definition| {
            try std.testing.expectEqualStrings(
                definition.provider_tool_name,
                tool.object.get("name").?.string,
            );
        }
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
