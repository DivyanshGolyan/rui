const std = @import("std");
const builtin = @import("builtin");
const execution = @import("execution.zig");
const protocol = @import("protocol.zig");
const store = @import("store.zig");
const transport_options = @import("transport_options");

const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const curl_version = "8.22.0";
pub const openssl_version = "OpenSSL/3.6.3";
pub const request_scratch_limit_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const response_observation_limit_bytes: usize = 64 * 1024;
pub const max_endpoint_bytes = 2048;
const per_input_framing_charge: u64 = 128;

pub const PreparationFaults = struct {
    first_step: bool = false,
    write: bool = false,
    seal: bool = false,
    unlink: bool = false,
};

pub const TransportOptions = struct {
    inactivity_seconds: c_long = 5 * 60,
};

pub const ScratchBudget = struct {
    used: *std.atomic.Value(u64),
    limit: u64,

    pub fn reserve(self: ScratchBudget, amount: u64) bool {
        if (amount > self.limit) return false;
        var current = self.used.load(.acquire);
        while (true) {
            const next = std.math.add(u64, current, amount) catch return false;
            if (next > self.limit) return false;
            current = self.used.cmpxchgWeak(current, next, .acq_rel, .acquire) orelse return true;
        }
    }

    pub fn release(self: ScratchBudget, amount: u64) void {
        const prior = self.used.fetchSub(amount, .acq_rel);
        std.debug.assert(prior >= amount);
    }
};

pub const PreparedRequest = struct {
    io: std.Io,
    file: std.Io.File,
    length: u64,
    charged: u64,
    budget: ScratchBudget,

    pub fn deinit(self: *PreparedRequest) void {
        self.file.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

pub const RetainedScratch = struct {
    io: std.Io,
    file: std.Io.File,
    scratch_path: protocol.Bounded(protocol.max_store_bytes + 64),
    name: protocol.Bounded(96),
    charged: u64,
    budget: ScratchBudget,

    pub fn cleanup(self: *RetainedScratch) !void {
        self.file.close(self.io);
        var scratch = try std.Io.Dir.cwd().openDir(self.io, self.scratch_path.slice(), .{});
        defer scratch.close(self.io);
        try scratch.deleteFile(self.io, self.name.slice());
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

const RequestWriter = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    fail_write: bool,

    fn write(self: *RequestWriter, bytes: []const u8) !void {
        if (self.fail_write) return error.InjectedRequestWriteFailure;
        try self.file.writeStreamingAll(self.io, bytes);
        self.offset = try std.math.add(u64, self.offset, bytes.len);
    }

    fn jsonString(self: *RequestWriter, value: []const u8) !void {
        try self.write("\"");
        try self.jsonBytes(value);
        try self.write("\"");
    }

    fn jsonContent(self: *RequestWriter, reader: *store.ContentReader) !void {
        try self.write("\"");
        var offset: u64 = 0;
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        while (offset < reader.reference.length) {
            const wanted: usize = @intCast(@min(reader.reference.length - offset, buffer.len));
            const count = try reader.read(offset, buffer[0..wanted]);
            if (count != wanted) return error.ShortCanonicalRead;
            try self.jsonBytes(buffer[0..count]);
            offset += count;
        }
        try self.write("\"");
    }

    fn rawContent(self: *RequestWriter, reader: *store.ContentReader) !void {
        var offset: u64 = 0;
        var buffer: [protocol.content_window_bytes]u8 = undefined;
        while (offset < reader.reference.length) {
            const wanted: usize = @intCast(@min(reader.reference.length - offset, buffer.len));
            const count = try reader.read(offset, buffer[0..wanted]);
            if (count != wanted) return error.ShortCanonicalRead;
            try self.write(buffer[0..count]);
            offset += count;
        }
    }

    fn jsonBytes(self: *RequestWriter, bytes: []const u8) !void {
        var run_start: usize = 0;
        for (bytes, 0..) |byte, index| {
            const needs_escape = switch (byte) {
                '"', '\\', '\n', '\r', '\t', 0...7, 11, 12, 14...31 => true,
                else => false,
            };
            if (!needs_escape) continue;
            if (run_start != index) try self.write(bytes[run_start..index]);
            try self.jsonByte(byte);
            run_start = index + 1;
        }
        if (run_start != bytes.len) try self.write(bytes[run_start..]);
    }

    fn jsonByte(self: *RequestWriter, byte: u8) !void {
        switch (byte) {
            '"' => try self.write("\\\""),
            '\\' => try self.write("\\\\"),
            '\n' => try self.write("\\n"),
            '\r' => try self.write("\\r"),
            '\t' => try self.write("\\t"),
            0...7, 11, 12, 14...31 => {
                const hex = "0123456789abcdef";
                try self.write(&.{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0x0f] });
            },
            else => try self.write(&.{byte}),
        }
    }
};

pub fn materialize(
    io: std.Io,
    view: *store.HistoricalView,
    scratch_path: []const u8,
    budget: ScratchBudget,
    faults: PreparationFaults,
    retained: *?RetainedScratch,
) !PreparedRequest {
    retained.* = null;
    if (faults.first_step) return error.InjectedFirstPreparationFailure;
    const settings = try view.settings();
    var maximum: u64 = 1024;
    maximum = try addEscapedMaximum(maximum, settings.model.len);
    if (settings.output_schema) |schema| maximum = try std.math.add(u64, maximum, schema.length);
    var after_revision: u64 = 0;
    while (try view.nextInstruction(after_revision)) |instruction| {
        maximum = try addEscapedMaximum(maximum, instruction.content.length);
        maximum = try std.math.add(u64, maximum, per_input_framing_charge);
        after_revision = instruction.revision;
    }
    var after: u64 = 0;
    while (try view.nextInput(after)) |input| {
        maximum = try addEscapedMaximum(maximum, input.content.length);
        maximum = try std.math.add(u64, maximum, per_input_framing_charge);
        after = input.admission_id;
    }
    if (!budget.reserve(maximum)) return error.RequestScratchExhausted;
    var budget_owned = true;
    errdefer if (budget_owned) budget.release(maximum);

    var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
    defer scratch.close(io);
    var name_buffer: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "request-{d}-{d}.tmp", .{
        view.binding.operation_id,
        view.binding.attempt_ordinal,
    });
    const file = try scratch.createFile(io, name, .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
    var file_owned = true;
    errdefer if (file_owned) file.close(io);
    if (faults.unlink) {
        var owned = RetainedScratch{
            .io = io,
            .file = file,
            .scratch_path = .{},
            .name = .{},
            .charged = maximum,
            .budget = budget,
        };
        owned.scratch_path.set(scratch_path) catch unreachable;
        owned.name.set(name) catch unreachable;
        retained.* = owned;
        file_owned = false;
        budget_owned = false;
        return error.InjectedRequestUnlinkFailure;
    }
    scratch.deleteFile(io, name) catch |err| {
        var owned = RetainedScratch{
            .io = io,
            .file = file,
            .scratch_path = .{},
            .name = .{},
            .charged = maximum,
            .budget = budget,
        };
        owned.scratch_path.set(scratch_path) catch unreachable;
        owned.name.set(name) catch unreachable;
        retained.* = owned;
        file_owned = false;
        budget_owned = false;
        return err;
    };

    var writer = RequestWriter{ .io = io, .file = file, .fail_write = faults.write };
    try writer.write("{\"model\":");
    try writer.jsonString(settings.model.slice());
    try writer.write(",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"input\":[");
    var input_comma = false;
    after_revision = 0;
    if (try view.nextInstruction(after_revision)) |baseline| {
        try writer.write("{\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":");
        var instructions = try view.openContent(baseline.content);
        try writer.jsonContent(&instructions);
        instructions.close();
        try writer.write("}]}");
        input_comma = true;
        after_revision = baseline.revision;
    }
    after = 0;
    while (try view.nextInput(after)) |input| {
        if (input_comma) try writer.write(",");
        try writer.write("{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":");
        var content = try view.openContent(input.content);
        try writer.jsonContent(&content);
        content.close();
        try writer.write("}]}");
        input_comma = true;
        after = input.admission_id;
    }
    while (try view.nextInstruction(after_revision)) |instruction| {
        if (input_comma) try writer.write(",");
        try writer.write("{\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":");
        var instructions = try view.openContent(instruction.content);
        try writer.jsonContent(&instructions);
        instructions.close();
        try writer.write("}]}");
        input_comma = true;
        after_revision = instruction.revision;
    }
    try writer.write("],\"tools\":[");
    var comma = false;
    if (settings.tools_mask & 1 != 0) {
        try writer.write("{\"type\":\"function\",\"name\":\"bash\",\"description\":\"Run Bash\"}");
        comma = true;
    }
    if (settings.tools_mask & 2 != 0) {
        if (comma) try writer.write(",");
        try writer.write("{\"type\":\"function\",\"name\":\"edit\",\"description\":\"Edit one file\"}");
    }
    try writer.write("]");
    if (settings.output_schema) |schema_reference| {
        try writer.write(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"latifa_output\",\"strict\":true,\"schema\":");
        var schema = try view.openContent(schema_reference);
        try writer.rawContent(&schema);
        schema.close();
        try writer.write("}}");
    }
    try writer.write("}");
    if (faults.seal) return error.InjectedRequestSealFailure;
    try file.sync(io);
    if (try file.length(io) != writer.offset) return error.RequestSealFailed;
    if (writer.offset > maximum) return error.RequestScratchAccountingFailure;
    file_owned = false;
    budget_owned = false;
    return .{ .io = io, .file = file, .length = writer.offset, .charged = maximum, .budget = budget };
}

fn addEscapedMaximum(current: u64, bytes: u64) !u64 {
    return std.math.add(u64, current, try std.math.mul(u64, bytes, 6));
}

pub const TransportClass = enum { permanent_http, temporary_http, transport_failure };

pub const TransportEvidence = struct {
    class: TransportClass,
    http_status: u16 = 0,
    response_bytes: u64 = 0,
};

pub const Completion = struct {
    easy: *c.CURL,
    result: c.CURLcode,
};

pub const Reactor = struct {
    multi: *c.CURLM,

    pub fn init() !Reactor {
        return .{ .multi = c.curl_multi_init() orelse return error.TransportAllocationFailed };
    }

    pub fn deinit(self: *Reactor) void {
        std.debug.assert(c.curl_multi_cleanup(self.multi) == c.CURLM_OK);
        self.* = undefined;
    }

    fn add(self: *Reactor, transfer: *Transfer) !void {
        transfer.armTimeout();
        if (c.curl_multi_add_handle(self.multi, transfer.easy) != c.CURLM_OK) {
            return error.TransportReactorAddFailed;
        }
        transfer.in_reactor = true;
    }

    pub fn remove(self: *Reactor, transfer: *Transfer) void {
        if (!transfer.in_reactor) return;
        std.debug.assert(c.curl_multi_remove_handle(self.multi, transfer.easy) == c.CURLM_OK);
        transfer.in_reactor = false;
    }

    pub fn drive(self: *Reactor, timeout_ms: c_int) !void {
        var running: c_int = 0;
        if (c.curl_multi_perform(self.multi, &running) != c.CURLM_OK) return error.TransportReactorFailed;
        if (running != 0) {
            var descriptors: c_int = 0;
            if (c.curl_multi_poll(self.multi, null, 0, timeout_ms, &descriptors) != c.CURLM_OK) {
                return error.TransportReactorFailed;
            }
            if (c.curl_multi_perform(self.multi, &running) != c.CURLM_OK) return error.TransportReactorFailed;
        }
    }

    pub fn nextCompletion(self: *Reactor) ?Completion {
        var remaining: c_int = 0;
        while (c.curl_multi_info_read(self.multi, &remaining)) |message| {
            if (message.*.msg != c.CURLMSG_DONE) continue;
            return .{ .easy = message.*.easy_handle.?, .result = message.*.data.result };
        }
        return null;
    }
};

pub fn initialize() !void {
    if (comptime !transport_options.enabled) return error.TransportUnavailableOnTarget;
    if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != c.CURLE_OK) return error.TransportInitializationFailed;
    errdefer c.curl_global_cleanup();
    const info = c.curl_version_info(c.CURLVERSION_NOW) orelse return error.TransportCapabilityMissing;
    if (!std.mem.eql(u8, std.mem.span(info.*.version), curl_version) or
        info.*.ssl_version == null or
        !std.mem.startsWith(u8, std.mem.span(info.*.ssl_version), openssl_version) or
        info.*.features & c.CURL_VERSION_SSL == 0 or
        info.*.features & c.CURL_VERSION_ASYNCHDNS == 0 or
        info.*.features & c.CURL_VERSION_THREADSAFE == 0)
    {
        return error.TransportCapabilityMissing;
    }
}

pub fn deinitialize() void {
    if (comptime transport_options.enabled) c.curl_global_cleanup();
}

const ReadContext = struct {
    io: std.Io,
    file: std.Io.File,
    offset: u64 = 0,
    length: u64,
    failed: bool = false,
};

const WriteContext = struct {
    bytes: u64 = 0,
    overflow: bool = false,
};

const TimeoutContext = struct {
    io: std.Io,
    inactivity_ns: i64,
    last_download: c.curl_off_t = 0,
    last_progress: std.Io.Clock.Timestamp = undefined,
    armed: bool = false,
};

pub const Transfer = struct {
    easy: *c.CURL,
    headers: ?*c.curl_slist,
    request: PreparedRequest,
    read_context: ReadContext,
    write_context: WriteContext = .{},
    timeout_context: TimeoutContext,
    in_reactor: bool = false,
    binding: store.AttemptBinding,

    pub fn start(
        self: *Transfer,
        endpoint: []const u8,
        request: PreparedRequest,
        binding: store.AttemptBinding,
        options: TransportOptions,
    ) !void {
        if (options.inactivity_seconds <= 0) return error.InvalidTransportTimeout;
        try validateEndpoint(endpoint);
        var endpoint_buffer: [max_endpoint_bytes + 1:0]u8 = undefined;
        const endpoint_z = try std.fmt.bufPrintZ(&endpoint_buffer, "{s}", .{endpoint});
        const easy = c.curl_easy_init() orelse return error.TransportAllocationFailed;
        errdefer c.curl_easy_cleanup(easy);
        var headers: ?*c.curl_slist = null;
        headers = c.curl_slist_append(headers, "Content-Type: application/json") orelse
            return error.TransportAllocationFailed;
        errdefer c.curl_slist_free_all(headers);
        self.* = .{
            .easy = easy,
            .headers = headers,
            .request = request,
            .read_context = .{ .io = request.io, .file = request.file, .length = request.length },
            .binding = binding,
            .timeout_context = .{
                .io = request.io,
                .inactivity_ns = options.inactivity_seconds * std.time.ns_per_s,
            },
        };
        try setOpt(easy, c.CURLOPT_URL, endpoint_z.ptr);
        try setOpt(easy, c.CURLOPT_POST, @as(c_long, 1));
        try setOpt(easy, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c.curl_off_t, @intCast(request.length)));
        try setOpt(easy, c.CURLOPT_READFUNCTION, readCallback);
        try setOpt(easy, c.CURLOPT_READDATA, &self.read_context);
        try setOpt(easy, c.CURLOPT_WRITEFUNCTION, writeCallback);
        try setOpt(easy, c.CURLOPT_WRITEDATA, &self.write_context);
        try setOpt(easy, c.CURLOPT_HTTPHEADER, headers);
        try setOpt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        try setOpt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, 0));
        try setOpt(easy, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        try setOpt(easy, c.CURLOPT_FRESH_CONNECT, @as(c_long, 1));
        try setOpt(easy, c.CURLOPT_FORBID_REUSE, @as(c_long, 1));
        try setOpt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, options.inactivity_seconds * 1000);
        try setOpt(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        try setOpt(easy, c.CURLOPT_XFERINFOFUNCTION, xferInfoCallback);
        try setOpt(easy, c.CURLOPT_XFERINFODATA, &self.timeout_context);
        try setOpt(easy, c.CURLOPT_HTTP_VERSION, @as(c_long, if (std.mem.startsWith(u8, endpoint, "http://"))
            c.CURL_HTTP_VERSION_1_1
        else
            c.CURL_HTTP_VERSION_2TLS));
        if (builtin.os.tag == .macos and !std.mem.startsWith(u8, endpoint, "http://")) {
            try setOpt(easy, c.CURLOPT_SSL_OPTIONS, @as(c_long, c.CURLSSLOPT_NATIVE_CA));
        }
    }

    pub fn evidence(self: *Transfer, result: c.CURLcode) !TransportEvidence {
        if (result != c.CURLE_OK or self.read_context.failed or self.write_context.overflow) {
            return .{ .class = .transport_failure, .response_bytes = self.write_context.bytes };
        }
        var response_code: c_long = 0;
        if (c.curl_easy_getinfo(self.easy, c.CURLINFO_RESPONSE_CODE, &response_code) != c.CURLE_OK or
            response_code < 100 or response_code > 599)
        {
            return error.InvalidHttpEvidence;
        }
        const status: u16 = @intCast(response_code);
        const class: TransportClass = if (status == 408 or status == 429 or status >= 500)
            .temporary_http
        else if (status >= 400)
            .permanent_http
        else
            .transport_failure;
        return .{ .class = class, .http_status = status, .response_bytes = self.write_context.bytes };
    }

    fn armTimeout(self: *Transfer) void {
        self.timeout_context.last_progress = std.Io.Clock.Timestamp.now(self.timeout_context.io, .awake);
        self.timeout_context.armed = true;
    }

    pub fn deinit(self: *Transfer) void {
        std.debug.assert(!self.in_reactor);
        c.curl_slist_free_all(self.headers);
        c.curl_easy_cleanup(self.easy);
        self.request.deinit();
        self.* = undefined;
    }
};

pub fn launch(
    reactor: *Reactor,
    transfer: *Transfer,
    custody: *execution.CustodyPool,
    token: execution.CustodyToken,
    storage: *store.Store,
) !void {
    try custody.consumeLaunchAuthority(token, transfer.binding);
    try storage.withDispatchHandoff(
        transfer.binding,
        .{ .reactor = reactor, .transfer = transfer },
        struct {
            fn handoff(context: anytype) !void {
                try context.reactor.add(context.transfer);
            }
        }.handoff,
    );
}

fn readCallback(pointer: [*c]u8, size: usize, count: usize, context_pointer: ?*anyopaque) callconv(.c) usize {
    const context: *ReadContext = @ptrCast(@alignCast(context_pointer orelse return c.CURL_READFUNC_ABORT));
    const capacity = std.math.mul(usize, size, count) catch return c.CURL_READFUNC_ABORT;
    const remaining = context.length - context.offset;
    const wanted: usize = @intCast(@min(remaining, capacity));
    if (wanted == 0) return 0;
    const actual = context.file.readPositionalAll(context.io, pointer[0..wanted], context.offset) catch {
        context.failed = true;
        return c.CURL_READFUNC_ABORT;
    };
    if (actual != wanted) {
        context.failed = true;
        return c.CURL_READFUNC_ABORT;
    }
    context.offset += actual;
    return actual;
}

fn xferInfoCallback(
    context_pointer: ?*anyopaque,
    _: c.curl_off_t,
    download_now: c.curl_off_t,
    _: c.curl_off_t,
    _: c.curl_off_t,
) callconv(.c) c_int {
    const context: *TimeoutContext = @ptrCast(@alignCast(context_pointer orelse return 1));
    if (!context.armed) return 0;
    const now = std.Io.Clock.Timestamp.now(context.io, .awake);
    if (download_now != context.last_download) {
        context.last_download = download_now;
        context.last_progress = now;
        return 0;
    }
    return if (context.last_progress.durationTo(now).raw.nanoseconds >= context.inactivity_ns) 1 else 0;
}

fn writeCallback(_: [*c]u8, size: usize, count: usize, context_pointer: ?*anyopaque) callconv(.c) usize {
    const context: *WriteContext = @ptrCast(@alignCast(context_pointer orelse return 0));
    const bytes = std.math.mul(usize, size, count) catch return 0;
    const next = std.math.add(u64, context.bytes, bytes) catch return 0;
    if (next > response_observation_limit_bytes) {
        context.overflow = true;
        return 0;
    }
    context.bytes = next;
    return bytes;
}

fn setOpt(easy: *c.CURL, option: c.CURLoption, value: anytype) !void {
    if (c.curl_easy_setopt(easy, option, value) != c.CURLE_OK) return error.TransportOptionFailed;
}

pub fn validateEndpoint(endpoint: []const u8) !void {
    if (endpoint.len == 0 or endpoint.len > max_endpoint_bytes or
        std.mem.indexOfScalar(u8, endpoint, 0) != null or !std.unicode.utf8ValidateSlice(endpoint))
    {
        return error.InvalidProviderEndpoint;
    }
    const uri = std.Uri.parse(endpoint) catch return error.InvalidProviderEndpoint;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidProviderEndpoint;
    var host_buffer: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = (uri.getHost(&host_buffer) catch return error.InvalidProviderEndpoint).bytes;
    if (host.len == 0) return error.InvalidProviderEndpoint;
    if (std.mem.eql(u8, uri.scheme, "https")) return;
    if (!std.mem.eql(u8, uri.scheme, "http")) return error.InvalidProviderEndpoint;
    if (std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "::1")) return;
    return error.InsecureProviderEndpoint;
}

test "scratch reservation is bounded and releases exact charge" {
    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 10 };
    try std.testing.expect(budget.reserve(7));
    try std.testing.expect(!budget.reserve(4));
    budget.release(7);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "endpoint validation permits TLS and loopback fixture HTTP only" {
    try validateEndpoint("https://chatgpt.com/backend-api/codex/responses");
    try validateEndpoint("http://127.0.0.1:9876/fail");
    try std.testing.expectError(error.InsecureProviderEndpoint, validateEndpoint("http://example.com/fail"));
    try std.testing.expectError(
        error.InvalidProviderEndpoint,
        validateEndpoint("http://127.0.0.1:80@example.com/fail"),
    );
    try std.testing.expectError(
        error.InvalidProviderEndpoint,
        validateEndpoint("http://127.0.0.1:80@127.0.0.1:9876/fail"),
    );
    try std.testing.expectError(error.InvalidProviderEndpoint, validateEndpoint("https://user@example.com/fail"));
    try std.testing.expectError(error.InsecureProviderEndpoint, validateEndpoint("http://[::1]evil:80/fail"));
}
