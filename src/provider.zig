const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const provider_output = @import("provider_output.zig");
const store = @import("store.zig");
const tools = @import("tools.zig");
const transport_options = @import("transport_options");

const c = @cImport({
    @cInclude("curl/curl.h");
    @cInclude("time.h");
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
    inactivity_seconds: i64 = 5 * 60,
    request_read_fault: bool = false,
    response_acquire_fault: bool = false,
    response_unlink_fault: bool = false,
    response_write_fault: bool = false,
    completion_identity_fault: CompletionIdentityFault = .none,
};

pub const CompletionIdentityFault = enum { none, missing, foreign, mismatched };

pub const ScratchBudget = protocol.ScratchBudget;

pub const PreparedRequest = struct {
    io: std.Io,
    file: std.Io.File,
    length: u64,
    charged: u64,
    budget: ScratchBudget,
    structured_output: bool,

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
    name: protocol.Bounded(96),
    charged: u64,
    budget: ScratchBudget,

    pub fn cleanup(self: *RetainedScratch, scratch_path: []const u8) !void {
        var scratch = try std.Io.Dir.cwd().openDir(self.io, scratch_path, .{});
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
    name: []const u8,
    budget: ScratchBudget,
    charged: u64,
) RetainedScratch {
    var retained = RetainedScratch{
        .io = io,
        .file = file,
        .secondary_file = secondary_file,
        .name = .{},
        .charged = charged,
        .budget = budget,
    };
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

    fn jsonContent(self: *RequestWriter, reader: *store.HistoricalReader) !void {
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

    fn rawContent(self: *RequestWriter, reader: *store.HistoricalReader) !void {
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
        retained.* = retainedNamedScratch(io, file, null, name, budget, 0);
        return err;
    };
    if (faults.unlink) {
        retained.* = retainedNamedScratch(io, file, readonly, name, budget, 0);
        return error.InjectedRequestUnlinkFailure;
    }
    scratch.deleteFile(io, name) catch |err| {
        retained.* = retainedNamedScratch(io, file, readonly, name, budget, 0);
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
        if (entry.kind == .tool_results) {
            var after_call_ordinal: ?u64 = null;
            while (try view.nextToolResult(entry.source_operation_id.?, after_call_ordinal)) |result| {
                if (input_comma) try writer.write(",");
                try writer.write("{\"type\":\"function_call_output\",\"call_id\":");
                {
                    var call_id = try view.openContent(result.call_id);
                    defer call_id.close();
                    try writer.jsonContent(&call_id);
                }
                try writer.write(",\"output\":");
                {
                    var output = try view.openContent(result.output);
                    defer output.close();
                    try writer.jsonContent(&output);
                }
                try writer.write("}");
                input_comma = true;
                after_call_ordinal = result.call_ordinal;
            }
        } else {
            if (input_comma) try writer.write(",");
            {
                var content = try view.openContent(entry.content.?);
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
        }
        after_position = entry.position;
    }
    try writer.write("],\"tools\":[");
    var comma = false;
    if (settings.tools_mask & 1 != 0) {
        try writer.write(tools.bash_definition_json);
        comma = true;
    }
    if (settings.tools_mask & 2 != 0) {
        if (comma) try writer.write(",");
        try writer.write("{\"type\":\"function\",\"name\":\"edit\",\"description\":\"Edit one file\"}");
    }
    try writer.write("]");
    if (settings.output_schema) |schema_reference| {
        try writer.write(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"rui_output\",\"strict\":true,\"schema\":");
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
        .structured_output = settings.output_schema != null,
    };
}

pub const TransportDisposition = enum {
    success,
    permanent_http,
    temporary_http,
    temporary_connection,
    permanent_transport,
    authentication_failure,
    tls_verification_failure,
    invalid_headers,
};

pub const TransportEvidence = struct {
    disposition: TransportDisposition,
    http_status: u16 = 0,
    response_bytes: u64 = 0,
    retry_after_ms: ?u64 = null,
    retry_after_deadline_ms: ?i64 = null,
};

pub const CaptureFailure = enum { scratch_exhausted, write_failed };

pub const TransferIdentity = *const opaque {};
pub const TransportHandleIdentity = *const opaque {};

pub const CompletionOutcome = union(enum) {
    response_capture_failed: CaptureFailure,
    request_source_failed,
    transport_finished: TransportEvidence,
};

pub const Completion = struct {
    identity: TransferIdentity,
    outcome: CompletionOutcome,
};

pub const TransferMembership = struct {
    context: *const anyopaque,
    find_fn: *const fn (*const anyopaque, TransportHandleIdentity) ?*Transfer,

    fn find(self: TransferMembership, handle: TransportHandleIdentity) ?*Transfer {
        return self.find_fn(self.context, handle);
    }
};

var foreign_completion_identity: u8 = 0;

pub const Reactor = struct {
    multi: *c.CURLM,

    pub fn init() !Reactor {
        return .{ .multi = c.curl_multi_init() orelse return error.TransportAllocationFailed };
    }

    pub fn deinit(self: *Reactor) void {
        std.debug.assert(c.curl_multi_cleanup(self.multi) == c.CURLM_OK);
        self.* = undefined;
    }

    pub fn add(self: *Reactor, transfer: *Transfer) !void {
        transfer.armTimeout();
        const private: ?*anyopaque = switch (transfer.completion_identity_fault) {
            .none => @ptrCast(transfer),
            .missing => null,
            .foreign => @ptrCast(&foreign_completion_identity),
            .mismatched => @ptrCast(&transfer.response),
        };
        try setOpt(transfer.easy, c.CURLOPT_PRIVATE, private);
        if (c.curl_multi_add_handle(self.multi, transfer.easy) != c.CURLM_OK) {
            return error.TransportReactorAddFailed;
        }
        transfer.in_reactor = true;
    }

    pub fn cancel(self: *Reactor, transfer: *Transfer) void {
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

    pub fn nextCompletion(self: *Reactor, membership: TransferMembership) !?Completion {
        var remaining: c_int = 0;
        while (c.curl_multi_info_read(self.multi, &remaining)) |message| {
            if (message.*.msg != c.CURLMSG_DONE) continue;
            const easy = message.*.easy_handle orelse return error.MissingTransportCompletionHandle;
            const result = message.*.data.result;
            const handle: TransportHandleIdentity = @ptrCast(easy);
            // Establish the actual fixed-slot owner from the completed native
            // handle before treating curl's private value as an identity. The
            // private pointer is compared only; it is never dereferenced.
            const transfer = membership.find(handle) orelse return error.UnknownTransportCompletion;
            if (!transfer.matchesHandle(handle)) return error.MismatchedTransportMembership;
            var private: ?*anyopaque = null;
            const private_result = c.curl_easy_getinfo(easy, c.CURLINFO_PRIVATE, &private);
            try self.removeCompleted(transfer);
            if (private_result != c.CURLE_OK) return error.TransportCompletionIdentityUnavailable;
            const private_pointer = private orelse return error.MissingTransportCompletionIdentity;
            const identity: TransferIdentity = @ptrCast(private_pointer);
            if (identity != transfer.identity()) return error.MismatchedTransportCompletionIdentity;
            return .{
                .identity = identity,
                .outcome = try transfer.completionOutcome(result),
            };
        }
        return null;
    }

    fn removeCompleted(self: *Reactor, transfer: *Transfer) !void {
        if (!transfer.in_reactor) return error.InactiveTransportCompletion;
        if (c.curl_multi_remove_handle(self.multi, transfer.easy) != c.CURLM_OK) {
            return error.TransportReactorRemoveFailed;
        }
        transfer.in_reactor = false;
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
    fail: bool = false,
    failed: bool = false,
};

pub const ResponseCapture = struct {
    io: std.Io,
    file: std.Io.File,
    readonly: ?std.Io.File,
    budget: ScratchBudget,
    length: u64 = 0,
    charged: u64 = 0,
    sealed: bool = false,
    fail_write: bool = false,
    failure: ?CaptureFailure = null,

    pub fn init(
        io: std.Io,
        scratch_path: []const u8,
        budget: ScratchBudget,
        binding: store.AttemptBinding,
        fail_acquire: bool,
        fail_unlink: bool,
        fail_write: bool,
        retained: *?RetainedScratch,
    ) !ResponseCapture {
        retained.* = null;
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
        const readonly = scratch.openFile(io, name, .{}) catch |err| {
            retained.* = retainedNamedScratch(io, file, null, name, budget, 0);
            return err;
        };
        if (fail_unlink) {
            retained.* = retainedNamedScratch(io, file, readonly, name, budget, 0);
            return error.InjectedResponseUnlinkFailure;
        }
        scratch.deleteFile(io, name) catch |err| {
            retained.* = retainedNamedScratch(io, file, readonly, name, budget, 0);
            return err;
        };
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
    openai_model: protocol.Bounded(protocol.max_model_bytes) = .{},
    x_openai_model: protocol.Bounded(protocol.max_model_bytes) = .{},
    retry_after_ms: ?u64 = null,
    retry_after_deadline_ms: ?i64 = null,
    invalid: bool = false,
};

const TimeoutContext = struct {
    io: std.Io,
    inactivity_ns: i64,
    last_download: c.curl_off_t = 0,
    last_progress: std.Io.Clock.Timestamp = undefined,
    armed: bool = false,
    expired: bool = false,
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
    completion_identity_fault: CompletionIdentityFault,
    binding: store.AttemptBinding,

    pub fn start(
        self: *Transfer,
        endpoint: []const u8,
        request: PreparedRequest,
        binding: store.AttemptBinding,
        options: TransportOptions,
        scratch_path: []const u8,
        response_budget: ScratchBudget,
        retained_response: *?RetainedScratch,
    ) !void {
        if (options.inactivity_seconds <= 0) return error.InvalidTransportTimeout;
        const inactivity_ns = std.math.mul(i64, options.inactivity_seconds, std.time.ns_per_s) catch
            return error.InvalidTransportTimeout;
        if (options.inactivity_seconds > std.math.maxInt(c_long)) return error.InvalidTransportTimeout;
        const connect_timeout_ms = std.math.mul(
            c_long,
            @as(c_long, @intCast(options.inactivity_seconds)),
            1000,
        ) catch return error.InvalidTransportTimeout;
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
            options.response_unlink_fault,
            options.response_write_fault,
            retained_response,
        ) catch return error.ResponseCaptureAcquisitionFailed;
        errdefer response.deinit();
        self.* = .{
            .easy = easy,
            .headers = headers,
            .request = request,
            .read_context = .{
                .io = request.io,
                .file = request.file,
                .length = request.length,
                .fail = options.request_read_fault,
            },
            .response = response,
            .binding = binding,
            .completion_identity_fault = options.completion_identity_fault,
            .timeout_context = .{
                .io = request.io,
                .inactivity_ns = inactivity_ns,
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
        try setOpt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, connect_timeout_ms);
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

    fn completionOutcome(self: *Transfer, result: c.CURLcode) !CompletionOutcome {
        if (self.response.failure) |failure| return .{ .response_capture_failed = failure };
        if (self.read_context.failed) return .request_source_failed;
        return .{ .transport_finished = try self.transportEvidence(result) };
    }

    fn transportEvidence(self: *Transfer, result: c.CURLcode) !TransportEvidence {
        const disposition: TransportDisposition = if (self.header_context.invalid)
            .invalid_headers
        else if (result != c.CURLE_OK)
            curlFailureDisposition(result, self.timeout_context.expired)
        else
            .success;
        if (disposition != .success) return .{
            .disposition = disposition,
            .response_bytes = self.response.length,
            .retry_after_ms = self.header_context.retry_after_ms,
            .retry_after_deadline_ms = self.header_context.retry_after_deadline_ms,
        };
        var response_code: c_long = 0;
        if (c.curl_easy_getinfo(self.easy, c.CURLINFO_RESPONSE_CODE, &response_code) != c.CURLE_OK or
            response_code < 100 or response_code > 599)
        {
            return error.InvalidHttpEvidence;
        }
        const status: u16 = @intCast(response_code);
        const http_disposition: TransportDisposition = if (status >= 200 and status < 300)
            .success
        else if (status == 408 or status == 429 or status >= 500)
            .temporary_http
        else
            .permanent_http;
        return .{
            .disposition = http_disposition,
            .http_status = status,
            .response_bytes = self.response.length,
            .retry_after_ms = self.header_context.retry_after_ms,
            .retry_after_deadline_ms = self.header_context.retry_after_deadline_ms,
        };
    }

    fn armTimeout(self: *Transfer) void {
        self.timeout_context.last_progress = std.Io.Clock.Timestamp.now(self.timeout_context.io, .awake);
        self.timeout_context.armed = true;
        self.timeout_context.expired = false;
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

    pub fn openaiModel(self: *const Transfer) []const u8 {
        return self.header_context.openai_model.slice();
    }

    pub fn xOpenaiModel(self: *const Transfer) []const u8 {
        return self.header_context.x_openai_model.slice();
    }

    pub fn identity(self: *const Transfer) TransferIdentity {
        return @ptrCast(self);
    }

    pub fn matchesHandle(self: *const Transfer, handle: TransportHandleIdentity) bool {
        return self.in_reactor and handle == @as(TransportHandleIdentity, @ptrCast(self.easy));
    }

    pub fn hasStructuredOutput(self: *const Transfer) bool {
        return self.request.structured_output;
    }
};

fn readCallback(pointer: [*c]u8, size: usize, count: usize, context_pointer: ?*anyopaque) callconv(.c) usize {
    const context: *ReadContext = @ptrCast(@alignCast(context_pointer orelse return c.CURL_READFUNC_ABORT));
    if (context.fail) {
        context.failed = true;
        return c.CURL_READFUNC_ABORT;
    }
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
    if (context.last_progress.durationTo(now).raw.nanoseconds >= context.inactivity_ns) {
        context.expired = true;
        return 1;
    }
    return 0;
}

fn curlFailureDisposition(result: c.CURLcode, inactivity_expired: bool) TransportDisposition {
    if (inactivity_expired and result == c.CURLE_ABORTED_BY_CALLBACK) return .temporary_connection;
    return switch (result) {
        c.CURLE_COULDNT_RESOLVE_PROXY,
        c.CURLE_COULDNT_RESOLVE_HOST,
        c.CURLE_COULDNT_CONNECT,
        c.CURLE_SEND_ERROR,
        c.CURLE_RECV_ERROR,
        c.CURLE_GOT_NOTHING,
        c.CURLE_PARTIAL_FILE,
        c.CURLE_OPERATION_TIMEDOUT,
        c.CURLE_HTTP2,
        c.CURLE_HTTP2_STREAM,
        c.CURLE_HTTP3,
        c.CURLE_QUIC_CONNECT_ERROR,
        c.CURLE_SSL_CONNECT_ERROR,
        => .temporary_connection,
        c.CURLE_LOGIN_DENIED => .authentication_failure,
        c.CURLE_PEER_FAILED_VERIFICATION => .tls_verification_failure,
        else => .permanent_transport,
    };
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
    if (std.ascii.eqlIgnoreCase(name, "retry-after")) {
        if (parseRetryAfter(value, c.time(null))) |constraint| switch (constraint) {
            .delay_ms => |delay| context.retry_after_ms = @max(context.retry_after_ms orelse 0, delay),
            .deadline_ms => |deadline| context.retry_after_deadline_ms = @max(context.retry_after_deadline_ms orelse 0, deadline),
        };
        return bytes;
    }
    const destination = if (std.ascii.eqlIgnoreCase(name, "x-request-id"))
        &context.request_id
    else if (std.ascii.eqlIgnoreCase(name, "openai-model"))
        &context.openai_model
    else if (std.ascii.eqlIgnoreCase(name, "x-openai-model"))
        &context.x_openai_model
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

const RetryAfter = union(enum) {
    delay_ms: u64,
    deadline_ms: i64,
};

fn parseRetryAfter(value: []const u8, now_seconds: c.time_t) ?RetryAfter {
    if (value.len == 0 or value.len > 128) return null;
    if (std.fmt.parseInt(u64, value, 10)) |seconds| {
        const delay_ms = std.math.mul(u64, seconds, 1000) catch return null;
        if (delay_ms > std.math.maxInt(i64)) return null;
        const now_ms = std.math.mul(i64, @intCast(now_seconds), 1000) catch return null;
        _ = std.math.add(i64, now_ms, @intCast(delay_ms)) catch return null;
        return .{ .delay_ms = delay_ms };
    } else |_| {}
    var buffer: [129:0]u8 = undefined;
    const value_z = std.fmt.bufPrintZ(&buffer, "{s}", .{value}) catch return null;
    const due_seconds = c.curl_getdate(value_z.ptr, null);
    if (due_seconds < 0) return null;
    const deadline_ms = std.math.mul(i64, @intCast(due_seconds), 1000) catch return null;
    return .{ .deadline_ms = deadline_ms };
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
    var used = std.atomic.Value(u64).init(0);
    var writer = RequestWriter{
        .io = std.testing.io,
        .file = file,
        .budget = .{ .used = &used, .limit = 1024 },
        .fail_write = false,
    };
    defer writer.deinit();
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

test "Retry-After preserves dates and delays without unchecked arithmetic" {
    try std.testing.expectEqual(RetryAfter{ .delay_ms = 12_000 }, parseRetryAfter("12", 1_700_000_000).?);
    try std.testing.expectEqual(RetryAfter{ .deadline_ms = 1_700_000_001_000 }, parseRetryAfter("Tue, 14 Nov 2023 22:13:21 GMT", 1_700_000_000).?);
    try std.testing.expectEqual(RetryAfter{ .deadline_ms = 1_699_999_999_000 }, parseRetryAfter("Tue, 14 Nov 2023 22:13:19 GMT", 1_700_000_000).?);
    try std.testing.expect(parseRetryAfter("9223372036854775", 1_700_000_000) == null);
    try std.testing.expect(parseRetryAfter("invalid", 1_700_000_000) == null);
    try std.testing.expect(parseRetryAfter("18446744073709551615", 1_700_000_000) == null);
}

test "duplicate Retry-After headers retain both independent constraints" {
    var context: HeaderContext = .{};
    const lines = [_][]const u8{
        "Retry-After: 12\r\n",
        "Retry-After: Tue, 14 Nov 2023 22:13:21 GMT\r\n",
        "Retry-After: 3\r\n",
        "Retry-After: 9223372036854775\r\n",
        "Retry-After: Tue, 14 Nov 2023 22:13:19 GMT\r\n",
        "Retry-After: invalid\r\n",
    };
    for (lines) |line| {
        try std.testing.expectEqual(line.len, headerCallback(@constCast(line.ptr), 1, line.len, &context));
    }
    try std.testing.expectEqual(@as(?u64, 12_000), context.retry_after_ms);
    try std.testing.expectEqual(@as(?i64, 1_700_000_001_000), context.retry_after_deadline_ms);
}

test "curl disposition retries only temporary connection and explicit inactivity failures" {
    try std.testing.expectEqual(
        TransportDisposition.temporary_connection,
        curlFailureDisposition(c.CURLE_COULDNT_CONNECT, false),
    );
    try std.testing.expectEqual(
        TransportDisposition.temporary_connection,
        curlFailureDisposition(c.CURLE_ABORTED_BY_CALLBACK, true),
    );
    try std.testing.expectEqual(
        TransportDisposition.permanent_transport,
        curlFailureDisposition(c.CURLE_ABORTED_BY_CALLBACK, false),
    );
    try std.testing.expectEqual(
        TransportDisposition.authentication_failure,
        curlFailureDisposition(c.CURLE_LOGIN_DENIED, false),
    );
    try std.testing.expectEqual(
        TransportDisposition.tls_verification_failure,
        curlFailureDisposition(c.CURLE_PEER_FAILED_VERIFICATION, false),
    );
}
