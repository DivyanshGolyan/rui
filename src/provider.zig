const std = @import("std");
const builtin = @import("builtin");
const execution = @import("execution.zig");
const protocol = @import("protocol.zig");
const provider_output = @import("provider_output.zig");
const store = @import("store.zig");
const transport_options = @import("transport_options");

const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const curl_version = "8.22.0";
pub const openssl_version = "OpenSSL/3.6.3";
pub const request_scratch_limit_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const max_endpoint_bytes = 2048;

pub const PreparationFaults = struct {
    first_step: bool = false,
    write: bool = false,
    seal: bool = false,
    unlink: bool = false,
};

pub const TransportOptions = struct {
    inactivity_seconds: c_long = 5 * 60,
    response_acquire_fault: bool = false,
    response_write_fault: bool = false,
};

pub const ScratchBudget = protocol.ScratchBudget;

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
    secondary_file: ?std.Io.File = null,
    scratch_path: protocol.Bounded(protocol.max_store_bytes + 64),
    name: protocol.Bounded(96),
    charged: u64,
    budget: ScratchBudget,

    pub fn cleanup(self: *RetainedScratch) !void {
        var scratch = try std.Io.Dir.cwd().openDir(self.io, self.scratch_path.slice(), .{});
        defer scratch.close(self.io);
        try scratch.deleteFile(self.io, self.name.slice());
        self.file.close(self.io);
        if (self.secondary_file) |file| file.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

fn retainedNamedScratch(
    io: std.Io,
    file: std.Io.File,
    secondary_file: ?std.Io.File,
    scratch_path: []const u8,
    name: []const u8,
    budget: ScratchBudget,
    charged: u64,
) RetainedScratch {
    var retained = RetainedScratch{
        .io = io,
        .file = file,
        .secondary_file = secondary_file,
        .scratch_path = .{},
        .name = .{},
        .charged = charged,
        .budget = budget,
    };
    retained.scratch_path.set(scratch_path) catch unreachable;
    retained.name.set(name) catch unreachable;
    return retained;
}

const RequestWriter = struct {
    io: std.Io,
    file: std.Io.File,
    budget: ScratchBudget,
    offset: u64 = 0,
    charged: u64 = 0,
    fail_write: bool,

    pub fn write(self: *RequestWriter, bytes: []const u8) !void {
        const next_offset = std.math.add(u64, self.offset, bytes.len) catch
            return error.RequestLengthOverflow;
        const next_charged = std.math.add(u64, self.charged, bytes.len) catch
            return error.RequestLengthOverflow;
        if (!self.budget.reserve(bytes.len)) return error.RequestScratchExhausted;
        // The complete slice is charged before the OS write. A partial/error
        // write retains that full reservation until both file aliases close.
        self.charged = next_charged;
        if (self.fail_write and self.offset != 0) return error.InjectedRequestWriteFailure;
        try self.file.writeStreamingAll(self.io, bytes);
        self.offset = next_offset;
    }

    fn deinit(self: *RequestWriter) void {
        self.file.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
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
        var encoder = JsonSink{ .request = self };
        std.json.Stringify.encodeJsonStringChars(bytes, .{}, &encoder.writer) catch {
            return encoder.failure.?;
        };
    }

    // Keep encoded writes under the request's failure and offset accounting.
    const JsonSink = struct {
        request: *RequestWriter,
        failure: ?anyerror = null,
        writer: std.Io.Writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *JsonSink = @fieldParentPtr("writer", writer);
            var count: usize = 0;
            for (data, 0..) |bytes, index| {
                const repeats = if (index == data.len - 1) splat else 1;
                for (0..repeats) |_| {
                    self.request.write(bytes) catch |err| {
                        self.failure = err;
                        return error.WriteFailed;
                    };
                    count += bytes.len;
                }
            }
            return count;
        }
    };
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
    var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
    defer scratch.close(io);
    var name_buffer: [96]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "request-{d}-{d}.tmp", .{
        view.binding.operation_id,
        view.binding.attempt_ordinal,
    });
    const file = try scratch.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
    const readonly = scratch.openFile(io, name, .{}) catch |err| {
        retained.* = retainedNamedScratch(io, file, null, scratch_path, name, budget, 0);
        return err;
    };
    if (faults.unlink) {
        retained.* = retainedNamedScratch(io, file, readonly, scratch_path, name, budget, 0);
        return error.InjectedRequestUnlinkFailure;
    }
    scratch.deleteFile(io, name) catch |err| {
        retained.* = retainedNamedScratch(io, file, readonly, scratch_path, name, budget, 0);
        return err;
    };

    var writer = RequestWriter{
        .io = io,
        .file = file,
        .budget = budget,
        .fail_write = faults.write,
    };
    var writer_owned = true;
    errdefer if (writer_owned) writer.deinit();
    // Error defers run in reverse order: close the read alias before the
    // writer owner releases any charged growth.
    var readonly_owned = true;
    errdefer if (readonly_owned) readonly.close(io);
    try writer.write("{\"model\":");
    try writer.jsonString(settings.model.slice());
    try writer.write(",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"input\":[");
    var input_comma = false;
    {
        try writer.write("{\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":");
        var baseline = try view.openContent(settings.baseline_instructions);
        defer baseline.close();
        try writer.jsonContent(&baseline);
        try writer.write("}]}");
    }
    input_comma = true;
    var after_position: u64 = 0;
    while (try view.nextEntry(after_position)) |entry| {
        if (input_comma) try writer.write(",");
        {
            var content = try view.openContent(entry.content);
            defer content.close();
            if (entry.kind == .provider_output) {
                try provider_output.writeReplayItem(&content, &writer);
            } else {
                try writer.write(if (entry.kind == .user)
                    "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":"
                else
                    "{\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":");
                try writer.jsonContent(&content);
                try writer.write("}]}");
            }
        }
        input_comma = true;
        after_position = entry.position;
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
        {
            var schema = try view.openContent(schema_reference);
            defer schema.close();
            try writer.rawContent(&schema);
        }
        try writer.write("}}");
    }
    try writer.write("}");
    if (faults.seal) return error.InjectedRequestSealFailure;
    try writer.file.sync(io);
    if (try readonly.length(io) != writer.offset) return error.RequestSealFailed;
    writer.file.close(io);
    writer_owned = false;
    readonly_owned = false;
    return .{
        .io = io,
        .file = readonly,
        .length = writer.offset,
        .charged = writer.charged,
        .budget = budget,
    };
}

pub const TransportClass = enum { success, permanent_http, temporary_http, transport_failure };

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

pub const ResponseCapture = struct {
    const Failure = enum { scratch_exhausted, write_failed };

    io: std.Io,
    file: std.Io.File,
    readonly: ?std.Io.File,
    budget: ScratchBudget,
    length: u64 = 0,
    charged: u64 = 0,
    sealed: bool = false,
    fail_write: bool = false,
    failure: ?Failure = null,

    pub fn init(
        io: std.Io,
        scratch_path: []const u8,
        budget: ScratchBudget,
        binding: store.AttemptBinding,
        fail_acquire: bool,
        fail_write: bool,
    ) !ResponseCapture {
        if (fail_acquire) return error.InjectedResponseAcquireFailure;
        var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
        defer scratch.close(io);
        var name_buffer: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "response-{d}-{d}.tmp", .{
            binding.operation_id,
            binding.attempt_ordinal,
        });
        const file = try scratch.createFile(io, name, .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        });
        errdefer file.close(io);
        errdefer scratch.deleteFile(io, name) catch {};
        const readonly = try scratch.openFile(io, name, .{});
        errdefer readonly.close(io);
        try scratch.deleteFile(io, name);
        return .{
            .io = io,
            .file = file,
            .readonly = readonly,
            .budget = budget,
            .fail_write = fail_write,
        };
    }

    fn write(self: *ResponseCapture, bytes: []const u8) !void {
        std.debug.assert(!self.sealed);
        if (self.fail_write) {
            self.failure = .write_failed;
            return error.InjectedResponseWriteFailure;
        }
        if (!self.budget.reserve(bytes.len)) {
            self.failure = .scratch_exhausted;
            return error.ResponseScratchExhausted;
        }
        const next_charged = std.math.add(u64, self.charged, bytes.len) catch {
            self.budget.release(bytes.len);
            self.failure = .write_failed;
            return error.ResponseLengthOverflow;
        };
        const next_length = std.math.add(u64, self.length, bytes.len) catch {
            self.budget.release(bytes.len);
            self.failure = .write_failed;
            return error.ResponseLengthOverflow;
        };
        // Retain the whole callback reservation after a partial OS write. The
        // failed capture is released immediately and never undercounts disk.
        self.charged = next_charged;
        self.file.writeStreamingAll(self.io, bytes) catch |err| {
            self.failure = .write_failed;
            return err;
        };
        self.length = next_length;
    }

    fn failureCode(self: *const ResponseCapture) ?[]const u8 {
        return if (self.failure) |failure| switch (failure) {
            .scratch_exhausted => "response_scratch_exhausted",
            .write_failed => "response_write_failed",
        } else null;
    }

    pub fn seal(self: *ResponseCapture, fail: bool) !void {
        std.debug.assert(!self.sealed);
        if (fail) return error.InjectedResponseSealFailure;
        try self.file.sync(self.io);
        if (try self.file.length(self.io) != self.length) return error.ResponseSealFailed;
        const readonly = self.readonly orelse return error.ResponseSealFailed;
        self.file.close(self.io);
        self.file = readonly;
        self.readonly = null;
        self.sealed = true;
    }

    pub fn deinit(self: *ResponseCapture) void {
        self.file.close(self.io);
        if (self.readonly) |readonly| readonly.close(self.io);
        self.budget.release(self.charged);
        self.* = undefined;
    }
};

const HeaderContext = struct {
    request_id: protocol.Bounded(256) = .{},
    served_model: protocol.Bounded(protocol.max_model_bytes) = .{},
    invalid: bool = false,
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
    response: ResponseCapture,
    response_owned: bool = true,
    header_context: HeaderContext = .{},
    timeout_context: TimeoutContext,
    in_reactor: bool = false,
    binding: store.AttemptBinding,

    pub fn start(
        self: *Transfer,
        endpoint: []const u8,
        request: PreparedRequest,
        binding: store.AttemptBinding,
        options: TransportOptions,
        scratch_path: []const u8,
        response_budget: ScratchBudget,
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
        var response = ResponseCapture.init(
            request.io,
            scratch_path,
            response_budget,
            binding,
            options.response_acquire_fault,
            options.response_write_fault,
        ) catch return error.ResponseCaptureAcquisitionFailed;
        errdefer response.deinit();
        self.* = .{
            .easy = easy,
            .headers = headers,
            .request = request,
            .read_context = .{ .io = request.io, .file = request.file, .length = request.length },
            .response = response,
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
        try setOpt(easy, c.CURLOPT_WRITEDATA, &self.response);
        try setOpt(easy, c.CURLOPT_HEADERFUNCTION, headerCallback);
        try setOpt(easy, c.CURLOPT_HEADERDATA, &self.header_context);
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
        if (result != c.CURLE_OK or self.read_context.failed or self.header_context.invalid) {
            return .{ .class = .transport_failure, .response_bytes = self.response.length };
        }
        var response_code: c_long = 0;
        if (c.curl_easy_getinfo(self.easy, c.CURLINFO_RESPONSE_CODE, &response_code) != c.CURLE_OK or
            response_code < 100 or response_code > 599)
        {
            return error.InvalidHttpEvidence;
        }
        const status: u16 = @intCast(response_code);
        const class: TransportClass = if (status >= 200 and status < 300)
            .success
        else if (status == 408 or status == 429 or status >= 500)
            .temporary_http
        else if (status >= 400)
            .permanent_http
        else
            .transport_failure;
        return .{ .class = class, .http_status = status, .response_bytes = self.response.length };
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
        if (self.response_owned) self.response.deinit();
        self.* = undefined;
    }

    pub fn takeResponse(self: *Transfer) ResponseCapture {
        std.debug.assert(self.response_owned);
        self.response_owned = false;
        return self.response;
    }

    pub fn requestId(self: *const Transfer) []const u8 {
        return self.header_context.request_id.slice();
    }

    pub fn servedModel(self: *const Transfer) []const u8 {
        return self.header_context.served_model.slice();
    }

    pub fn responseFailureCode(self: *const Transfer) ?[]const u8 {
        return self.response.failureCode();
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

fn writeCallback(pointer: [*c]u8, size: usize, count: usize, context_pointer: ?*anyopaque) callconv(.c) usize {
    const context: *ResponseCapture = @ptrCast(@alignCast(context_pointer orelse return 0));
    const bytes = std.math.mul(usize, size, count) catch return 0;
    context.write(pointer[0..bytes]) catch return 0;
    return bytes;
}

fn headerCallback(pointer: [*c]u8, size: usize, count: usize, context_pointer: ?*anyopaque) callconv(.c) usize {
    const context: *HeaderContext = @ptrCast(@alignCast(context_pointer orelse return 0));
    const bytes = std.math.mul(usize, size, count) catch return 0;
    const line = pointer[0..bytes];
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return bytes;
    const name = std.mem.trim(u8, line[0..colon], " \t");
    const value = std.mem.trim(u8, line[colon + 1 ..], " \t\r\n");
    const destination = if (std.ascii.eqlIgnoreCase(name, "x-request-id"))
        &context.request_id
    else if (std.ascii.eqlIgnoreCase(name, "openai-model") or std.ascii.eqlIgnoreCase(name, "x-openai-model"))
        &context.served_model
    else
        return bytes;
    if (value.len == 0 or (destination.len != 0 and !destination.eql(value))) {
        context.invalid = true;
        return 0;
    }
    destination.set(value) catch {
        context.invalid = true;
        return 0;
    };
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

test "request writer charges exact growth and seals through a readonly descriptor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var used = std.atomic.Value(u64).init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 7 };
    const file = try tmp.dir.createFile(std.testing.io, "request", .{ .exclusive = true });
    const readonly = try tmp.dir.openFile(std.testing.io, "request", .{});
    try tmp.dir.deleteFile(std.testing.io, "request");
    var writer = RequestWriter{
        .io = std.testing.io,
        .file = file,
        .budget = budget,
        .fail_write = true,
    };
    var writer_owned = true;
    defer if (writer_owned) writer.deinit();
    var readonly_owned = true;
    defer if (readonly_owned) readonly.close(std.testing.io);
    try writer.write("abc");
    try std.testing.expectError(error.InjectedRequestWriteFailure, writer.write("defg"));
    try std.testing.expectEqual(@as(u64, 3), writer.offset);
    try std.testing.expectEqual(@as(u64, 7), writer.charged);
    try std.testing.expectEqual(@as(u64, 7), used.load(.acquire));
    try writer.file.sync(std.testing.io);
    try std.testing.expectEqual(@as(u64, 3), try readonly.length(std.testing.io));
    try std.testing.expectError(error.NotOpenForWriting, readonly.writeStreamingAll(std.testing.io, "x"));
    readonly.close(std.testing.io);
    readonly_owned = false;
    writer.deinit();
    writer_owned = false;
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

test "request JSON encoding preserves controls and split UTF-8 with write failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "request", .{ .read = true });
    defer file.close(std.testing.io);
    var used = std.atomic.Value(u64).init(0);
    var writer = RequestWriter{
        .io = std.testing.io,
        .file = file,
        .budget = .{ .used = &used, .limit = 1024 },
        .fail_write = false,
    };
    const input = "quote\" slash\\ newline\n\r\t\x00\x08\x0b\x0c\x1f café";
    try writer.write("\"");
    // Canonical read windows can divide a multibyte character.
    try writer.jsonBytes(input[0 .. input.len - 1]);
    try writer.jsonBytes(input[input.len - 1 ..]);
    try writer.write("\"");
    var buffer: [256]u8 = undefined;
    const count = try file.readPositionalAll(std.testing.io, &buffer, 0);
    try std.testing.expectEqual(writer.offset, count);
    const parsed = try std.json.parseFromSlice([]const u8, std.testing.allocator, buffer[0..count], .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(input, parsed.value);
    writer.fail_write = true;
    try std.testing.expectError(error.InjectedRequestWriteFailure, writer.jsonBytes("\x0c"));
    try std.testing.expectEqual(@as(u64, count), writer.offset);
    try std.testing.expectEqual(@as(u64, count), try file.length(std.testing.io));
}
