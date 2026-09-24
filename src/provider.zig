const std = @import("std");
const builtin = @import("builtin");
const named_scratch = @import("named_scratch.zig");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const request_encoding = @import("request_encoding.zig");
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
    // Test-owned removal gate for the retained unlink-failure owner. When
    // set alongside unlink, the retained owner uses this gate so the test
    // can complete reclamation through the production path.
    unlink_removal: ?*const std.atomic.Value(bool) = null,
};

pub const TransportOptions = struct {
    ca_file: ?[]const u8 = null,
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

fn retainedNamedScratch(
    io: std.Io,
    file: std.Io.File,
    secondary_file: ?std.Io.File,
    name: []const u8,
    budget: ScratchBudget,
    charged: u64,
    removal: named_scratch.Removal,
) named_scratch.Owner {
    return .init(io, file, secondary_file, name, budget, charged, removal);
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
};

pub const preparation_byte_allowance = 16 * 1024;
pub const preparation_item_allowance = 64;

pub const PreparationProgress = union(enum) {
    pending,
    prepared: PreparedRequest,
    failed: anyerror,
};

pub const PreparationAdvanceStats = struct {
    work_bytes: usize,
    work_items: usize,
    request_bytes: u64,
};

const writePlainJsonRun = request_encoding.writePlainJsonRun;

// The native source adapter preserves the exact-read contract: the cursor
// selects a bounded refill size first, and any short canonical read fails.
const HistoricalSource = struct {
    reader: *store.HistoricalReader,

    pub fn contentLength(self: HistoricalSource) u64 {
        return self.reader.reference.length;
    }

    pub fn readContent(self: HistoricalSource, offset: u64, destination: []u8) !usize {
        return self.reader.read(offset, destination);
    }

    pub fn maxWindow(self: HistoricalSource, offset: u64, wanted: usize) usize {
        _ = self;
        _ = offset;
        return wanted;
    }
};

pub const Preparation = struct {
    view: store.HistoricalView,
    settings: ?store.HistoricalSettings = null,
    writer: RequestWriter,
    readonly: std.Io.File,
    faults: PreparationFaults,
    phase: Phase = .settings,
    next_phase: Phase = .settings,
    emission: Emission = .none,
    after_position: u64 = 0,
    input_comma: bool = false,
    current_entry: ?store.HistoricalEntry = null,
    current_tool_result: ?store.HistoricalToolResult = null,
    active: bool = true,
    last_advance: PreparationAdvanceStats = .{ .work_bytes = 0, .work_items = 0, .request_bytes = 0 },

    const Phase = enum {
        settings,
        model_prefix,
        model,
        envelope,
        baseline,
        baseline_content,
        baseline_suffix,
        history_next,
        entry_comma,
        entry_prefix,
        entry_content,
        entry_suffix,
        tool_result_next,
        tool_result_prefix,
        tool_call_id,
        tool_result_middle,
        tool_output,
        tool_result_suffix,
        tools_prefix,
        bash_tool,
        edit_tool,
        tools_suffix,
        schema_prefix,
        schema,
        schema_suffix,
        request_suffix,
        seal,
        emitting,
        complete,
    };

    const JsonEmission = struct {
        bytes: ?[]const u8 = null,
        reader: ?store.HistoricalReader = null,
        cursor: request_encoding.JsonCursor = .{},

        fn close(self: *JsonEmission) void {
            if (self.reader) |*reader| reader.close();
            self.reader = null;
        }
    };

    const RawEmission = struct {
        reader: store.HistoricalReader,
        cursor: request_encoding.RawCursor = .{},
    };

    const ReplayEmission = struct {
        reader: store.HistoricalReader,
        cursor: request_encoding.ReplayCursor = .{},
    };

    const Emission = union(enum) {
        none,
        fixed: struct { bytes: []const u8, cursor: request_encoding.FixedCursor = .{} },
        json: JsonEmission,
        raw: RawEmission,
        replay: ReplayEmission,
    };

    pub fn init(
        self: *Preparation,
        io: std.Io,
        view: store.HistoricalView,
        scratch_path: []const u8,
        budget: ScratchBudget,
        faults: PreparationFaults,
        retained: *?named_scratch.Owner,
    ) !void {
        retained.* = null;
        var owned_view = view;
        errdefer owned_view.close();
        if (faults.first_step) return error.InjectedFirstPreparationFailure;
        var scratch = try std.Io.Dir.cwd().openDir(io, scratch_path, .{});
        defer scratch.close(io);
        var name_buffer: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "request-{d}-{d}.tmp", .{
            view.binding.operation_id,
            view.binding.attempt_ordinal,
        });
        const file = try scratch.createFile(io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) });
        const readonly = scratch.openFile(io, name, .{}) catch |err| {
            retained.* = retainedNamedScratch(io, file, null, name, budget, 0, .native);
            return err;
        };
        if (faults.unlink) {
            const removal: named_scratch.Removal = if (faults.unlink_removal) |gate| .{ .gated = gate } else .injected_failure;
            retained.* = retainedNamedScratch(io, file, readonly, name, budget, 0, removal);
            return error.InjectedRequestUnlinkFailure;
        }
        scratch.deleteFile(io, name) catch |err| {
            retained.* = retainedNamedScratch(io, file, readonly, name, budget, 0, .native);
            return err;
        };
        self.* = .{
            .view = owned_view,
            .writer = .{
                .io = io,
                .file = file,
                .budget = budget,
                .fail_write = faults.write,
            },
            .readonly = readonly,
            .faults = faults,
        };
    }

    pub fn advance(self: *Preparation, byte_allowance: usize, item_allowance: usize) PreparationProgress {
        std.debug.assert(self.active and byte_allowance != 0 and item_allowance != 0);
        var bytes_left = byte_allowance;
        var items_left = item_allowance;
        defer self.last_advance = .{
            .work_bytes = byte_allowance - bytes_left,
            .work_items = item_allowance - items_left,
            .request_bytes = self.writer.offset,
        };
        while (bytes_left != 0 and items_left != 0) {
            if (self.phase == .emitting) {
                const finished = self.advanceEmission(&bytes_left, &items_left) catch |err| return .{ .failed = err };
                if (!finished) return .pending;
                self.phase = self.next_phase;
                continue;
            }
            items_left -= 1;
            switch (self.phase) {
                .settings => {
                    self.settings = self.view.settings() catch |err| return .{ .failed = err };
                    self.phase = switch (self.settings.?.provider) {
                        .codex => .model_prefix,
                    };
                },
                .model_prefix => self.emitFixed("{\"model\":\"", .model),
                .model => self.emitJsonBytes(self.settings.?.model.slice(), .envelope),
                .envelope => self.emitFixed("\",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"input\":[", .baseline),
                .baseline => self.emitFixed("{\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":\"", .baseline_content),
                .baseline_content => {
                    const reader = self.view.openContent(self.settings.?.baseline_instructions) catch |err| return .{ .failed = err };
                    self.emitJsonReader(reader, .baseline_suffix);
                },
                .baseline_suffix => {
                    self.input_comma = true;
                    self.emitFixed("\"}]}", .history_next);
                },
                .history_next => {
                    const entry = self.view.nextEntry(self.after_position) catch |err| return .{ .failed = err };
                    self.current_entry = entry;
                    if (entry == null) {
                        self.phase = .tools_prefix;
                    } else if (entry.?.kind == .tool_results) {
                        self.phase = .tool_result_next;
                    } else self.phase = .entry_comma;
                },
                .entry_comma => {
                    if (self.input_comma) self.emitFixed(",", .entry_prefix) else self.phase = .entry_prefix;
                },
                .entry_prefix => {
                    const entry = self.current_entry.?;
                    if (entry.kind == .provider_output) {
                        const reader = self.view.openContent(entry.content.?) catch |err| return .{ .failed = err };
                        self.emitReplay(reader, .entry_suffix);
                    } else {
                        const prefix = if (entry.kind == .user)
                            "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\""
                        else
                            "{\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":\"";
                        self.emitFixed(prefix, .entry_content);
                    }
                },
                .entry_content => {
                    const reader = self.view.openContent(self.current_entry.?.content.?) catch |err| return .{ .failed = err };
                    self.emitJsonReader(reader, .entry_suffix);
                },
                .entry_suffix => {
                    const entry = self.current_entry.?;
                    self.after_position = entry.position;
                    self.input_comma = true;
                    self.current_entry = null;
                    if (entry.kind == .provider_output) self.phase = .history_next else self.emitFixed("\"}]}", .history_next);
                },
                .tool_result_next => {
                    const result = self.view.nextToolResult() catch |err| return .{ .failed = err };
                    self.current_tool_result = result;
                    if (result == null) {
                        self.after_position = self.current_entry.?.position;
                        self.current_entry = null;
                        self.phase = .history_next;
                    } else self.phase = .tool_result_prefix;
                },
                .tool_result_prefix => {
                    const prefix = if (self.input_comma)
                        ",{\"type\":\"function_call_output\",\"call_id\":\""
                    else
                        "{\"type\":\"function_call_output\",\"call_id\":\"";
                    self.emitFixed(prefix, .tool_call_id);
                },
                .tool_call_id => {
                    const reader = self.view.openContent(self.current_tool_result.?.call_id) catch |err| return .{ .failed = err };
                    self.emitJsonReader(reader, .tool_result_middle);
                },
                .tool_result_middle => self.emitFixed("\",\"output\":\"", .tool_output),
                .tool_output => {
                    const reader = self.view.openContent(self.current_tool_result.?.output) catch |err| return .{ .failed = err };
                    self.emitJsonReader(reader, .tool_result_suffix);
                },
                .tool_result_suffix => {
                    self.input_comma = true;
                    self.current_tool_result = null;
                    self.emitFixed("\"}", .tool_result_next);
                },
                .tools_prefix => self.emitFixed("],\"tools\":[", .bash_tool),
                .bash_tool => {
                    if (self.settings.?.tools_mask & 1 != 0) {
                        self.emitFixed(tools.bash_definition_json, .edit_tool);
                    } else self.phase = .edit_tool;
                },
                .edit_tool => {
                    if (self.settings.?.tools_mask & 2 != 0) {
                        self.emitFixed(if (self.settings.?.tools_mask & 1 != 0)
                            ",{\"type\":\"function\",\"name\":\"edit\",\"description\":\"Edit one file\"}"
                        else
                            "{\"type\":\"function\",\"name\":\"edit\",\"description\":\"Edit one file\"}", .tools_suffix);
                    } else self.phase = .tools_suffix;
                },
                .tools_suffix => {
                    if (self.settings.?.output_schema != null) self.emitFixed("]", .schema_prefix) else self.emitFixed("]", .request_suffix);
                },
                .schema_prefix => self.emitFixed(",\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"rui_output\",\"strict\":true,\"schema\":", .schema),
                .schema => {
                    const reader = self.view.openContent(self.settings.?.output_schema.?) catch |err| return .{ .failed = err };
                    self.emitRawReader(reader, .schema_suffix);
                },
                .schema_suffix => self.emitFixed("}}", .request_suffix),
                .request_suffix => self.emitFixed("}", .seal),
                .seal => return self.seal() catch |err| .{ .failed = err },
                .complete => unreachable,
                .emitting => unreachable,
            }
        }
        return .pending;
    }

    pub fn advanceStats(self: *const Preparation) PreparationAdvanceStats {
        return self.last_advance;
    }

    fn emitFixed(self: *Preparation, bytes: []const u8, next: Phase) void {
        self.emission = .{ .fixed = .{ .bytes = bytes } };
        self.next_phase = next;
        self.phase = .emitting;
    }

    fn emitJsonBytes(self: *Preparation, bytes: []const u8, next: Phase) void {
        self.emission = .{ .json = .{ .bytes = bytes } };
        self.next_phase = next;
        self.phase = .emitting;
    }

    fn emitJsonReader(self: *Preparation, reader: store.HistoricalReader, next: Phase) void {
        self.emission = .{ .json = .{ .reader = reader } };
        self.next_phase = next;
        self.phase = .emitting;
    }

    fn emitRawReader(self: *Preparation, reader: store.HistoricalReader, next: Phase) void {
        self.emission = .{ .raw = .{ .reader = reader } };
        self.next_phase = next;
        self.phase = .emitting;
    }

    fn emitReplay(self: *Preparation, reader: store.HistoricalReader, next: Phase) void {
        self.emission = .{ .replay = .{ .reader = reader } };
        self.next_phase = next;
        self.phase = .emitting;
    }

    fn advanceEmission(self: *Preparation, bytes_left: *usize, items_left: *usize) !bool {
        switch (self.emission) {
            .none => unreachable,
            .fixed => |*fixed| {
                if (!try fixed.cursor.advance(fixed.bytes, &self.writer, bytes_left)) return false;
            },
            .json => |*json| {
                if (!try self.advanceJson(json, bytes_left)) return false;
                json.close();
            },
            .raw => |*raw| {
                const source = HistoricalSource{ .reader = &raw.reader };
                if (!try raw.cursor.advance(source, &self.writer, bytes_left)) return false;
                raw.reader.close();
            },
            .replay => |*replay| {
                const source = HistoricalSource{ .reader = &replay.reader };
                if (try replay.cursor.advance(source, &self.writer, bytes_left, items_left) == .pending) return false;
                replay.reader.close();
            },
        }
        self.emission = .none;
        return true;
    }

    fn advanceJson(self: *Preparation, json: *JsonEmission, bytes_left: *usize) !bool {
        if (json.bytes) |bytes| {
            const source = request_encoding.MemorySource{ .bytes = bytes };
            return json.cursor.advance(source, &self.writer, bytes_left);
        }
        const source = HistoricalSource{ .reader = &json.reader.? };
        return json.cursor.advance(source, &self.writer, bytes_left);
    }

    fn seal(self: *Preparation) !PreparationProgress {
        if (self.faults.seal) return error.InjectedRequestSealFailure;
        try self.writer.file.sync(self.writer.io);
        if (try self.readonly.length(self.writer.io) != self.writer.offset) return error.RequestSealFailed;
        self.closeEmission();
        self.view.close();
        self.writer.file.close(self.writer.io);
        const request = PreparedRequest{
            .io = self.writer.io,
            .file = self.readonly,
            .length = self.writer.offset,
            .charged = self.writer.charged,
            .budget = self.writer.budget,
            .structured_output = self.settings.?.output_schema != null,
        };
        self.active = false;
        self.phase = .complete;
        return .{ .prepared = request };
    }

    pub fn cancel(self: *Preparation) void {
        std.debug.assert(self.active);
        self.closeEmission();
        self.view.close();
        self.readonly.close(self.writer.io);
        self.writer.deinit();
        self.active = false;
    }

    /// Preparation-local integrity check. Inspects the current production
    /// preparation without mutating it. The legal checkpoint is a stable
    /// point between synchronous advances, while the preparation remains
    /// in its final storage under the existing single-owner discipline.
    /// Must not be called after cancellation or sealing: the writer is
    /// consumed and an inactive preparation owns no request resources.
    /// Reuses the view's reader count, borrowed-reference ownership, and
    /// reader-active facts; no outstanding-reader registry is added.
    pub fn checkIntegrity(self: *Preparation, expected: store.AttemptBinding) !void {
        if (!self.active) return error.PreparationInactive;
        if (!self.view.isActive()) return error.HistoricalViewInactive;
        if (!self.view.bindingMatches(expected)) return error.PreparationBindingMismatch;
        if (self.settings) |frozen| {
            if (!self.view.ownsSettings(frozen)) return error.PreparationForeignContent;
        }
        var expected_readers: usize = 0;
        switch (self.emission) {
            .none, .fixed => {},
            .json => |*json| {
                if (json.reader) |*reader| {
                    expected_readers = 1;
                    if (!reader.ownedBy(&self.view)) return error.PreparationForeignReader;
                }
            },
            .raw => |*raw| {
                expected_readers = 1;
                if (!raw.reader.ownedBy(&self.view)) return error.PreparationForeignReader;
            },
            .replay => |*replay| {
                expected_readers = 1;
                if (!replay.reader.ownedBy(&self.view)) return error.PreparationForeignReader;
            },
        }
        if (self.view.outstandingReaders() != expected_readers) return error.PreparationReaderCountMismatch;
    }

    fn closeEmission(self: *Preparation) void {
        switch (self.emission) {
            .json => |*json| json.close(),
            .raw => |*raw| raw.reader.close(),
            .replay => |*replay| replay.reader.close(),
            .none, .fixed => {},
        }
        self.emission = .none;
    }
};

pub const TransportDisposition = enum {
    success,
    permanent_http,
    temporary_http,
    temporary_connection,
    permanent_transport,
    authentication_failure,
    tls_verification_failure,
    invalid_headers,
    unsupported_http_version,
};

pub const TransportEvidence = struct {
    disposition: TransportDisposition,
    http_status: u16 = 0,
    retry_after_ms: ?u64 = null,
    retry_after_deadline_ms: ?i64 = null,
};

pub const CaptureFailure = enum { scratch_exhausted, write_failed, seal_failed };

pub const TransferIdentity = *const opaque {};
pub const TransportHandleIdentity = *const opaque {};

pub const CompletionOutcome = union(enum) {
    response_capture_failed: CaptureFailure,
    request_source_failed,
    transport_finished: TransportEvidence,
};

pub const Completion = struct {
    outcome: CompletionOutcome,
    queued_after: usize,
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

    pub const Advance = enum { not_ready, progressed, resume_capture_failure };

    pub fn init(capacity: usize) !Reactor {
        const multi = c.curl_multi_init() orelse return error.TransportAllocationFailed;
        errdefer _ = c.curl_multi_cleanup(multi);
        const connections = capacity / 100 + @intFromBool(capacity % 100 != 0);
        if (connections > std.math.maxInt(c_long) or
            c.curl_multi_setopt(multi, c.CURLMOPT_PIPELINING, @as(c_long, c.CURLPIPE_MULTIPLEX)) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_MAX_CONCURRENT_STREAMS, @as(c_long, 100)) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_MAX_HOST_CONNECTIONS, @as(c_long, @intCast(connections))) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_MAX_TOTAL_CONNECTIONS, @as(c_long, @intCast(connections))) != c.CURLM_OK or
            c.curl_multi_setopt(multi, c.CURLMOPT_MAXCONNECTS, @as(c_long, @intCast(connections))) != c.CURLM_OK)
        {
            return error.TransportCapabilityMissing;
        }
        return .{ .multi = multi };
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

    pub fn discard(self: *Reactor, transfer: *Transfer) void {
        self.cancel(transfer);
        transfer.discard();
    }

    pub fn advance(self: *Reactor, transfer: *Transfer, response_write_on_resume: *bool) !Advance {
        if (!transfer.isReceiving()) return .not_ready;
        if (transfer.captureFailure()) |failure| {
            self.cancel(transfer);
            transfer.finish(.{ .response_capture_failed = failure }, 0);
            return .progressed;
        }
        if (transfer.in_reactor and transfer.timeout_context.isPaused() and transfer.writer.hasRoom()) {
            if (response_write_on_resume.*) {
                transfer.response.fail_write = true;
                response_write_on_resume.* = false;
            }
            // Clear before unpausing: curl may synchronously pause again in its callback.
            transfer.timeout_context.resumeAfterPause(std.Io.Clock.Timestamp.now(transfer.timeout_context.io, .awake));
            const result = c.curl_easy_pause(transfer.easy, c.CURLPAUSE_CONT);
            if (result != c.CURLE_OK) {
                const outcome = try transfer.completionOutcome(result);
                self.cancel(transfer);
                transfer.finish(outcome, 0);
                return if (transfer.captureFailure() != null) .resume_capture_failure else .progressed;
            }
            return .progressed;
        }
        if (!transfer.queueDeadlineExpired()) return .not_ready;
        self.cancel(transfer);
        transfer.finish(.{ .transport_finished = .{ .disposition = .temporary_connection } }, 0);
        return .progressed;
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

    // Separate waiting from curl callbacks so service timing never subtracts
    // callback/capture work as though it were an idle wait.
    pub fn wait(self: *Reactor, timeout_ms: c_int) !void {
        var descriptors: c_int = 0;
        if (c.curl_multi_poll(self.multi, null, 0, timeout_ms, &descriptors) != c.CURLM_OK) {
            return error.TransportReactorFailed;
        }
    }

    // Non-destructive count of finished easy handles whose CURLMSG_DONE has
    // not been consumed through curl_multi_info_read. This is not a second
    // completion owner and must not replace identity-checked removal.
    pub fn unprocessedCompletions(self: *Reactor) !u64 {
        var value: c.curl_off_t = 0;
        if (c.curl_multi_get_offt(self.multi, c.CURLMINFO_XFERS_DONE, &value) != c.CURLM_OK) {
            return error.TransportReactorFailed;
        }
        if (value < 0) return error.TransportReactorFailed;
        return @intCast(value);
    }

    pub fn nextCompletion(self: *Reactor, membership: TransferMembership) !bool {
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
            transfer.finish(try transfer.completionOutcome(result), @intCast(@max(remaining, 0)));
            return true;
        }
        return false;
    }

    fn removeCompleted(self: *Reactor, transfer: *Transfer) !void {
        if (!transfer.in_reactor) return error.InactiveTransportCompletion;
        if (c.curl_multi_remove_handle(self.multi, transfer.easy) != c.CURLM_OK) {
            return error.TransportReactorRemoveFailed;
        }
        transfer.in_reactor = false;
    }
};

// The reactor never performs capture I/O. All accepted callback bytes live in
// this fixed queue until the single writer finishes, including its active
// entry. A paused callback has accepted nothing and curl will redeliver it.
pub const CaptureWriter = struct {
    const capacity = 16;
    const Entry = struct {
        capture: *ResponseCapture,
        length: usize = 0,
        bytes: [c.CURL_MAX_WRITE_SIZE]u8 = undefined,
        seal: bool = false,
        fail_seal: bool = false,
    };

    io: std.Io,
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    entries: [capacity]Entry = undefined,
    head: usize = 0,
    count: usize = 0,
    stopping: bool = false,
    test_gate_path: ?[]const u8 = null,
    test_gate_min_written_bytes: usize = 0,

    pub fn run(self: *CaptureWriter) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.count == 0 and !self.stopping) self.available.waitUncancelable(self.io, &self.mutex);
            if (self.count == 0 and self.stopping) {
                self.mutex.unlock(self.io);
                return;
            }
            self.processOne();
        }
    }

    // The caller holds the queue mutex; the active entry stays counted while
    // I/O runs without it. Tests drive this same transition without a thread.
    fn processOne(self: *CaptureWriter) void {
        std.debug.assert(self.count != 0);
        const entry = &self.entries[self.head];
        const capture = entry.capture;
        const failed = capture.failure != null;
        self.mutex.unlock(self.io);

        if (entry.seal) {
            if (!failed) capture.seal(entry.fail_seal) catch {
                self.mutex.lockUncancelable(self.io);
                capture.failure = .seal_failed;
                self.mutex.unlock(self.io);
            };
        } else if (!failed) {
            if (self.test_gate_path) |path| if (capture.length >= self.test_gate_min_written_bytes) {
                self.test_gate_path = null;
                std.debug.print("{{\"rui_test_phase\":\"capture_write_gate_entered\",\"written_bytes\":{d}}}\n", .{capture.length});
                if (std.Io.Dir.cwd().openFile(self.io, path, .{})) |gate| {
                    defer gate.close(self.io);
                    var release: [1]u8 = undefined;
                    _ = gate.readStreaming(self.io, &.{&release}) catch {};
                } else |_| {}
            };
            capture.file.writeStreamingAll(capture.io, entry.bytes[0..entry.length]) catch {
                self.mutex.lockUncancelable(self.io);
                capture.failure = .write_failed;
                self.mutex.unlock(self.io);
            };
        }

        self.mutex.lockUncancelable(self.io);
        if (!entry.seal and capture.failure == null) capture.length += entry.length;
        capture.pending_writes -= 1;
        self.head = (self.head + 1) % capacity;
        self.count -= 1;
        self.mutex.unlock(self.io);
    }

    pub fn stop(self: *CaptureWriter, thread: std.Thread) void {
        self.mutex.lockUncancelable(self.io);
        self.stopping = true;
        self.available.signal(self.io);
        self.mutex.unlock(self.io);
        thread.join();
        std.debug.assert(self.count == 0);
    }

    fn offer(self: *CaptureWriter, capture: *ResponseCapture, bytes: []const u8) usize {
        std.debug.assert(bytes.len <= c.CURL_MAX_WRITE_SIZE);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (capture.failure != null) return 0;
        if (self.count == capacity) return c.CURL_WRITEFUNC_PAUSE;
        if (capture.fail_write) {
            capture.failure = .write_failed;
            return 0;
        }
        if (!capture.budget.reserve(bytes.len)) {
            capture.failure = .scratch_exhausted;
            return 0;
        }
        capture.charged = std.math.add(u64, capture.charged, bytes.len) catch {
            capture.budget.release(bytes.len);
            capture.failure = .write_failed;
            return 0;
        };
        const entry = &self.entries[(self.head + self.count) % capacity];
        entry.* = .{ .capture = capture, .length = bytes.len };
        @memcpy(entry.bytes[0..bytes.len], bytes);
        capture.pending_writes += 1;
        self.count += 1;
        self.available.signal(self.io);
        return bytes.len;
    }

    pub fn seal(self: *CaptureWriter, capture: *ResponseCapture, fail: bool) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.count == capacity) return false;
        self.entries[(self.head + self.count) % capacity] = .{
            .capture = capture,
            .seal = true,
            .fail_seal = fail,
        };
        capture.pending_writes += 1;
        self.count += 1;
        self.available.signal(self.io);
        return true;
    }

    pub fn drained(self: *CaptureWriter, capture: *ResponseCapture) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return capture.pending_writes == 0;
    }

    pub fn hasRoom(self: *CaptureWriter) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.count < capacity;
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
        info.*.features & c.CURL_VERSION_HTTP2 == 0 or
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
    pending_writes: usize = 0,

    pub fn init(
        io: std.Io,
        scratch_path: []const u8,
        budget: ScratchBudget,
        binding: store.AttemptBinding,
        fail_acquire: bool,
        fail_unlink: bool,
        fail_write: bool,
        retained: *?named_scratch.Owner,
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
            retained.* = retainedNamedScratch(io, file, null, name, budget, 0, .native);
            return err;
        };
        if (fail_unlink) {
            retained.* = retainedNamedScratch(io, file, readonly, name, budget, 0, .injected_failure);
            return error.InjectedResponseUnlinkFailure;
        }
        scratch.deleteFile(io, name) catch |err| {
            retained.* = retainedNamedScratch(io, file, readonly, name, budget, 0, .native);
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
        std.debug.assert(self.pending_writes == 0);
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
    paused_at: ?std.Io.Clock.Timestamp = null,
    armed: bool = false,
    expired: bool = false,

    fn isPaused(self: *const TimeoutContext) bool {
        return self.paused_at != null;
    }

    fn pause(self: *TimeoutContext, now: std.Io.Clock.Timestamp) void {
        std.debug.assert(self.paused_at == null);
        self.paused_at = now;
    }

    fn resumeAfterPause(self: *TimeoutContext, now: std.Io.Clock.Timestamp) void {
        const paused_at = self.paused_at orelse unreachable;
        self.last_progress = self.last_progress.addDuration(paused_at.durationTo(now));
        self.paused_at = null;
    }

    fn noteDownload(self: *TimeoutContext, now: std.Io.Clock.Timestamp, downloaded: c.curl_off_t) void {
        if (downloaded == self.last_download) return;
        self.last_download = downloaded;
        self.last_progress = now;
    }

    fn expiredAt(self: *TimeoutContext, now: std.Io.Clock.Timestamp) bool {
        if (!self.armed or self.isPaused()) return false;
        if (self.last_progress.durationTo(now).raw.nanoseconds < self.inactivity_ns) return false;
        self.expired = true;
        return true;
    }
};

pub const Transfer = struct {
    const Local = union(enum) {
        receiving,
        finished: struct { completion: Completion, seal_queued: bool = false },
        discarded,
    };

    pub const Finalization = union(enum) { pending, discarded, ready: Completion };

    easy: *c.CURL,
    headers: ?*c.curl_slist,
    request: PreparedRequest,
    read_context: ReadContext,
    response: ResponseCapture,
    writer: *CaptureWriter,
    local: Local = .receiving,
    response_owned: bool = true,
    header_context: HeaderContext = .{},
    error_buffer: [c.CURL_ERROR_SIZE]u8 = @splat(0),
    timeout_context: TimeoutContext,
    in_reactor: bool = false,
    completion_identity_fault: CompletionIdentityFault,
    binding: store.AttemptBinding,
    requires_h2: bool,

    pub fn start(
        self: *Transfer,
        endpoint: []const u8,
        request: PreparedRequest,
        binding: store.AttemptBinding,
        options: TransportOptions,
        writer: *CaptureWriter,
        scratch_path: []const u8,
        response_budget: ScratchBudget,
        retained_response: *?named_scratch.Owner,
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
            .writer = writer,
            .binding = binding,
            .requires_h2 = !std.mem.startsWith(u8, endpoint, "http://"),
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
        try setOpt(easy, c.CURLOPT_SEEKFUNCTION, seekCallback);
        try setOpt(easy, c.CURLOPT_SEEKDATA, &self.read_context);
        try setOpt(easy, c.CURLOPT_UPLOAD_BUFFERSIZE, @as(c_long, 16 * 1024));
        try setOpt(easy, c.CURLOPT_WRITEFUNCTION, writeCallback);
        try setOpt(easy, c.CURLOPT_WRITEDATA, self);
        try setOpt(easy, c.CURLOPT_HEADERFUNCTION, headerCallback);
        try setOpt(easy, c.CURLOPT_HEADERDATA, &self.header_context);
        try setOpt(easy, c.CURLOPT_ERRORBUFFER, self.error_buffer[0..].ptr);
        try setOpt(easy, c.CURLOPT_HTTPHEADER, headers);
        try setOpt(easy, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 0));
        try setOpt(easy, c.CURLOPT_MAXREDIRS, @as(c_long, 0));
        try setOpt(easy, c.CURLOPT_NOSIGNAL, @as(c_long, 1));
        if (options.ca_file) |path| {
            var ca_buffer: [std.posix.PATH_MAX + 1:0]u8 = undefined;
            const ca_z = std.fmt.bufPrintZ(&ca_buffer, "{s}", .{path}) catch return error.InvalidProviderCaFile;
            if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidProviderCaFile;
            try setOpt(easy, c.CURLOPT_CAINFO, ca_z.ptr);
        }
        try setOpt(easy, c.CURLOPT_CONNECTTIMEOUT_MS, connect_timeout_ms);
        try setOpt(easy, c.CURLOPT_NOPROGRESS, @as(c_long, 0));
        try setOpt(easy, c.CURLOPT_XFERINFOFUNCTION, xferInfoCallback);
        try setOpt(easy, c.CURLOPT_XFERINFODATA, &self.timeout_context);
        try setOpt(easy, c.CURLOPT_HTTP_VERSION, @as(c_long, if (std.mem.startsWith(u8, endpoint, "http://"))
            c.CURL_HTTP_VERSION_1_1
        else
            c.CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE));
        if (builtin.os.tag == .macos and !std.mem.startsWith(u8, endpoint, "http://")) {
            try setOpt(easy, c.CURLOPT_SSL_OPTIONS, @as(c_long, c.CURLSSLOPT_NATIVE_CA));
        }
    }

    fn completionOutcome(self: *Transfer, result: c.CURLcode) !CompletionOutcome {
        if (self.captureFailure()) |failure| return .{ .response_capture_failed = failure };
        if (self.read_context.failed) return .request_source_failed;
        return .{ .transport_finished = try self.transportEvidence(result) };
    }

    fn captureFailure(self: *Transfer) ?CaptureFailure {
        self.writer.mutex.lockUncancelable(self.writer.io);
        defer self.writer.mutex.unlock(self.writer.io);
        return self.response.failure;
    }

    fn finish(self: *Transfer, outcome: CompletionOutcome, queued_after: usize) void {
        std.debug.assert(self.local == .receiving);
        self.local = .{ .finished = .{ .completion = .{ .outcome = outcome, .queued_after = queued_after } } };
    }

    fn isReceiving(self: *const Transfer) bool {
        return self.local == .receiving;
    }

    pub fn isDiscarded(self: *const Transfer) bool {
        return self.local == .discarded;
    }

    fn discard(self: *Transfer) void {
        self.local = .discarded;
    }

    // Transport completion is preliminary until all accepted writes (and a
    // successful response seal) finish. Cancellation retains the same capture
    // until the writer has no outstanding reference to it.
    pub fn advanceFinalization(self: *Transfer, fail_seal: bool) Finalization {
        switch (self.local) {
            .receiving => return .pending,
            .discarded => {
                std.debug.assert(!self.in_reactor);
                return if (self.writer.drained(&self.response)) .discarded else .pending;
            },
            .finished => |*finished| {
                std.debug.assert(!self.in_reactor);
                if (!finished.seal_queued and self.captureFailure() == null) {
                    switch (finished.completion.outcome) {
                        .transport_finished => |evidence| if (evidence.disposition == .success) {
                            if (!self.writer.seal(&self.response, fail_seal)) return .pending;
                            finished.seal_queued = true;
                        },
                        else => {},
                    }
                }
                if (!self.writer.drained(&self.response)) return .pending;
                var ready = finished.completion;
                if (self.captureFailure()) |failure|
                    ready.outcome = .{ .response_capture_failed = failure };
                return .{ .ready = ready };
            },
        }
    }

    fn transportEvidence(self: *Transfer, result: c.CURLcode) !TransportEvidence {
        var version: c_long = 0;
        if (c.curl_easy_getinfo(self.easy, c.CURLINFO_HTTP_VERSION, &version) != c.CURLE_OK)
            return error.InvalidHttpEvidence;
        // Only the patched TLS ALPN guard emits this marker. A negotiated H2
        // stream can also fail with CURLE_HTTP2 before any response version.
        if (self.requires_h2 and result == c.CURLE_HTTP2 and
            std.mem.startsWith(u8, &self.error_buffer, "RUI_ALPN_H2_REQUIRED:"))
            return .{ .disposition = .unsupported_http_version };
        const disposition: TransportDisposition = if (self.header_context.invalid)
            .invalid_headers
        else if (result != c.CURLE_OK)
            curlFailureDisposition(result, self.timeout_context.expired)
        else
            .success;
        if (result == c.CURLE_OK) {
            if (version != (if (!self.requires_h2)
                c.CURL_HTTP_VERSION_1_1
            else
                c.CURL_HTTP_VERSION_2_0))
            {
                return .{ .disposition = .unsupported_http_version };
            }
        }
        if (disposition != .success) return .{
            .disposition = disposition,
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
            .retry_after_ms = self.header_context.retry_after_ms,
            .retry_after_deadline_ms = self.header_context.retry_after_deadline_ms,
        };
    }

    fn armTimeout(self: *Transfer) void {
        self.timeout_context.last_progress = std.Io.Clock.Timestamp.now(self.timeout_context.io, .awake);
        self.timeout_context.paused_at = null;
        self.timeout_context.armed = true;
        self.timeout_context.expired = false;
    }

    // curl does not invoke progress callbacks for an easy waiting in the
    // multi connection queue. The reactor owner checks the same clock so
    // waiting consumes this Attempt's inactivity interval too.
    fn queueDeadlineExpired(self: *Transfer) bool {
        const timeout = &self.timeout_context;
        return timeout.expiredAt(std.Io.Clock.Timestamp.now(timeout.io, .awake));
    }

    pub fn deinit(self: *Transfer) void {
        std.debug.assert(!self.in_reactor);
        std.debug.assert(self.writer.drained(&self.response));
        c.curl_slist_free_all(self.headers);
        c.curl_easy_cleanup(self.easy);
        self.request.deinit();
        if (self.response_owned) self.response.deinit();
        self.* = undefined;
    }

    pub fn takeResponse(self: *Transfer) ResponseCapture {
        std.debug.assert(self.response_owned);
        std.debug.assert(self.response.sealed);
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

fn seekCallback(context_pointer: ?*anyopaque, offset: c.curl_off_t, origin: c_int) callconv(.c) c_int {
    const context: *ReadContext = @ptrCast(@alignCast(context_pointer orelse return c.CURL_SEEKFUNC_FAIL));
    if (origin != c.SEEK_SET or offset < 0 or offset > context.length) return c.CURL_SEEKFUNC_FAIL;
    context.offset = @intCast(offset);
    return c.CURL_SEEKFUNC_OK;
}

fn xferInfoCallback(
    context_pointer: ?*anyopaque,
    _: c.curl_off_t,
    download_now: c.curl_off_t,
    _: c.curl_off_t,
    _: c.curl_off_t,
) callconv(.c) c_int {
    const context: *TimeoutContext = @ptrCast(@alignCast(context_pointer orelse return 1));
    if (!context.armed or context.isPaused()) return 0;
    const now = std.Io.Clock.Timestamp.now(context.io, .awake);
    context.noteDownload(now, download_now);
    return @intFromBool(context.expiredAt(now));
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
    const transfer: *Transfer = @ptrCast(@alignCast(context_pointer orelse return 0));
    const bytes = std.math.mul(usize, size, count) catch return 0;
    const accepted = transfer.writer.offer(&transfer.response, pointer[0..bytes]);
    if (accepted == c.CURL_WRITEFUNC_PAUSE and !transfer.timeout_context.isPaused()) {
        transfer.timeout_context.pause(std.Io.Clock.Timestamp.now(transfer.timeout_context.io, .awake));
    }
    return accepted;
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

test "request writer failure retains the full reservation until the owner releases" {
    // The budget arithmetic test covers reserve/release totals; this drives
    // the real RequestWriter failure seam with independently chosen input
    // lengths on a nonzero unrelated baseline.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(41);
    const budget = ScratchBudget{ .used = &used, .limit = 100 };
    const file = try tmp.dir.createFile(std.testing.io, "request-failure", .{ .exclusive = true });
    var writer = RequestWriter{
        .io = std.testing.io,
        .file = file,
        .budget = budget,
        .fail_write = true,
    };
    var writer_owned = true;
    defer if (writer_owned) writer.deinit();
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    // Five bytes submit successfully from a zero offset.
    try writer.write("hello");
    try std.testing.expectEqual(@as(u64, 5), writer.offset);
    try std.testing.expectEqual(@as(u64, 5), writer.charged);
    try std.testing.expectEqual(@as(u64, 46), used.load(.acquire));
    // Seven more bytes reserve the full slice, then fail after charging:
    // the outstanding contribution is 12 reserved bytes, the successful
    // offset stays 5, and only the owning cleanup path releases it.
    try std.testing.expectError(error.InjectedRequestWriteFailure, writer.write("bye-bye"));
    try std.testing.expectEqual(@as(u64, 5), writer.offset);
    try std.testing.expectEqual(@as(u64, 12), writer.charged);
    try std.testing.expectEqual(@as(u64, 53), used.load(.acquire));
    // Crossing the remaining shared limit is rejected before either the
    // injected write seam or the real file sees the slice. The successful
    // offset, submitted reservation, and file length all stay unchanged.
    try std.testing.expectError(error.RequestScratchExhausted, writer.write("x" ** 48));
    try std.testing.expectEqual(@as(u64, 5), writer.offset);
    try std.testing.expectEqual(@as(u64, 12), writer.charged);
    try std.testing.expectEqual(@as(u64, 53), used.load(.acquire));
    try std.testing.expectEqual(@as(u64, 5), try writer.file.length(std.testing.io));
    writer.deinit();
    writer_owned = false;
    try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
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

test "idle reactor reports zero unprocessed completions without consuming messages" {
    try initialize();
    defer c.curl_global_cleanup();
    for ([_]usize{ 1, 100, 101, 1000 }) |capacity| {
        var reactor = try Reactor.init(capacity);
        defer reactor.deinit();
        try std.testing.expectEqual(@as(u64, 0), try reactor.unprocessedCompletions());
        try std.testing.expectEqual(@as(u64, 0), try reactor.unprocessedCompletions());
    }
}

test "sealed POST source rewinds only within its complete length" {
    var context = ReadContext{ .io = undefined, .file = undefined, .length = 129, .offset = 101 };
    try std.testing.expectEqual(@as(c_int, c.CURL_SEEKFUNC_OK), seekCallback(&context, 0, c.SEEK_SET));
    try std.testing.expectEqual(@as(u64, 0), context.offset);
    try std.testing.expectEqual(@as(c_int, c.CURL_SEEKFUNC_OK), seekCallback(&context, 129, c.SEEK_SET));
    try std.testing.expectEqual(@as(c_int, c.CURL_SEEKFUNC_FAIL), seekCallback(&context, 130, c.SEEK_SET));
    try std.testing.expectEqual(@as(c_int, c.CURL_SEEKFUNC_FAIL), seekCallback(&context, -1, c.SEEK_SET));
    try std.testing.expectEqual(@as(c_int, c.CURL_SEEKFUNC_FAIL), seekCallback(&context, 0, c.SEEK_CUR));
    try std.testing.expectEqual(@as(u64, 129), context.offset);
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

test "local capture pause excludes only its own duration from inactivity" {
    const now = std.Io.Clock.Timestamp.now(std.testing.io, .awake);
    var timeout = TimeoutContext{
        .io = std.testing.io,
        .inactivity_ns = std.time.ns_per_s,
        .last_progress = now.subDuration(.{ .raw = .fromMilliseconds(250), .clock = .awake }),
        .armed = true,
    };
    timeout.pause(now);
    var transfer: Transfer = undefined;
    transfer.timeout_context = timeout;
    try std.testing.expect(!transfer.queueDeadlineExpired());
    try std.testing.expectEqual(@as(c_int, 0), xferInfoCallback(&transfer.timeout_context, 0, 0, 0, 0));
    try std.testing.expect(!transfer.timeout_context.expired);
    const resume_at = now.addDuration(.{ .raw = .fromSeconds(5), .clock = .awake });
    transfer.timeout_context.resumeAfterPause(resume_at);
    try std.testing.expectEqual(@as(i96, 250 * std.time.ns_per_ms), transfer.timeout_context.last_progress.durationTo(resume_at).raw.nanoseconds);
    var boundary = transfer.timeout_context;
    try std.testing.expect(!boundary.expiredAt(resume_at.addDuration(.{ .raw = .fromMilliseconds(749), .clock = .awake })));
    try std.testing.expect(boundary.expiredAt(resume_at.addDuration(.{ .raw = .fromMilliseconds(750), .clock = .awake })));
    const second_pause = resume_at.addDuration(.{ .raw = .fromMilliseconds(100), .clock = .awake });
    transfer.timeout_context.pause(second_pause);
    try std.testing.expect(!transfer.timeout_context.expiredAt(second_pause.addDuration(.{ .raw = .fromSeconds(2), .clock = .awake })));
    const second_resume = second_pause.addDuration(.{ .raw = .fromSeconds(2), .clock = .awake });
    transfer.timeout_context.resumeAfterPause(second_resume);
    boundary = transfer.timeout_context;
    try std.testing.expect(!boundary.expiredAt(second_resume.addDuration(.{ .raw = .fromMilliseconds(649), .clock = .awake })));
    try std.testing.expect(boundary.expiredAt(second_resume.addDuration(.{ .raw = .fromMilliseconds(650), .clock = .awake })));
    transfer.timeout_context.noteDownload(second_resume, 12);
    try std.testing.expect(!transfer.timeout_context.expiredAt(second_resume.addDuration(.{ .raw = .fromMilliseconds(999), .clock = .awake })));
    try std.testing.expect(transfer.timeout_context.expiredAt(second_resume.addDuration(.{ .raw = .fromSeconds(1), .clock = .awake })));
    transfer.timeout_context.last_progress = now.subDuration(.{ .raw = .fromSeconds(2), .clock = .awake });
    try std.testing.expect(transfer.queueDeadlineExpired());

    // A synchronous callback during curl_easy_pause can pause again. The
    // cleared timestamp is the only pause state it needs to update.
    var writer = CaptureWriter{ .io = std.testing.io, .count = CaptureWriter.capacity };
    transfer.writer = &writer;
    transfer.response.failure = null;
    transfer.timeout_context.paused_at = null;
    var byte = [_]u8{'x'};
    try std.testing.expectEqual(@as(usize, c.CURL_WRITEFUNC_PAUSE), writeCallback(&byte, 1, 1, &transfer));
    try std.testing.expect(transfer.timeout_context.isPaused());
    try std.testing.expect(!transfer.timeout_context.expiredAt(now.addDuration(.{ .raw = .fromSeconds(10), .clock = .awake })));
}

test "Transfer finalization waits for real writer drainage and seals once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "capture", .{ .read = true });
    const readonly = try tmp.dir.openFile(std.testing.io, "capture", .{});
    try tmp.dir.deleteFile(std.testing.io, "capture");
    var used = std.atomic.Value(u64).init(0);
    var writer = CaptureWriter{ .io = std.testing.io };
    var transfer: Transfer = undefined;
    transfer.writer = &writer;
    transfer.response = .{
        .io = std.testing.io,
        .file = file,
        .readonly = readonly,
        .budget = .{ .used = &used, .limit = 100 },
    };
    defer transfer.response.deinit();
    transfer.local = .receiving;
    transfer.in_reactor = false;

    try std.testing.expect(transfer.advanceFinalization(false) == .pending);
    try std.testing.expectEqual(@as(usize, 3), writer.offer(&transfer.response, "abc"));
    try std.testing.expectEqual(@as(u64, 3), used.load(.acquire));
    transfer.finish(.{ .transport_finished = .{ .disposition = .success } }, 7);
    try std.testing.expect(transfer.advanceFinalization(false) == .pending);
    try std.testing.expectEqual(@as(usize, 2), writer.count); // write and seal both remain owned
    writer.mutex.lockUncancelable(writer.io);
    writer.processOne();
    try std.testing.expect(transfer.advanceFinalization(false) == .pending);
    try std.testing.expectEqual(@as(u64, 3), transfer.response.length);
    writer.mutex.lockUncancelable(writer.io);
    writer.processOne();
    const ready = transfer.advanceFinalization(false);
    try std.testing.expect(ready == .ready);
    try std.testing.expect(ready.ready.outcome == .transport_finished);
    try std.testing.expectEqual(@as(usize, 7), ready.ready.queued_after);
    try std.testing.expect(transfer.response.sealed);
    try std.testing.expectEqual(@as(usize, 0), writer.count);
    try std.testing.expect(transfer.advanceFinalization(false) == .ready);
    try std.testing.expectEqual(@as(usize, 0), writer.count);
}

test "full capture queue rejects an offer without changing its charge or pending writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(std.testing.io, "full-queue", .{ .read = true });
    const readonly = try tmp.dir.openFile(std.testing.io, "full-queue", .{});
    try tmp.dir.deleteFile(std.testing.io, "full-queue");
    var used = std.atomic.Value(u64).init(0);
    var writer = CaptureWriter{ .io = std.testing.io };
    var capture = ResponseCapture{
        .io = std.testing.io,
        .file = file,
        .readonly = readonly,
        .budget = .{ .used = &used, .limit = CaptureWriter.capacity + 1 },
    };
    for (0..CaptureWriter.capacity) |_| try std.testing.expectEqual(@as(usize, 1), writer.offer(&capture, "x"));
    try std.testing.expectEqual(@as(usize, CaptureWriter.capacity), writer.count);
    try std.testing.expectEqual(@as(u64, CaptureWriter.capacity), used.load(.acquire));
    try std.testing.expectEqual(@as(usize, c.CURL_WRITEFUNC_PAUSE), writer.offer(&capture, "y"));
    try std.testing.expectEqual(@as(usize, CaptureWriter.capacity), capture.pending_writes);
    try std.testing.expectEqual(@as(u64, CaptureWriter.capacity), capture.charged);
    try std.testing.expectEqual(@as(u64, CaptureWriter.capacity), used.load(.acquire));
    for (0..CaptureWriter.capacity) |_| {
        writer.mutex.lockUncancelable(writer.io);
        writer.processOne();
    }
    try std.testing.expectEqual(@as(usize, 0), writer.count);
    try std.testing.expectEqual(@as(u64, CaptureWriter.capacity), capture.length);
    capture.deinit();
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "Transfer finalization records late capture failure and retains discarded writes and seals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var used = std.atomic.Value(u64).init(41);
    var writer = CaptureWriter{ .io = std.testing.io };
    for ([_]enum { write_failure, seal_failure, discard, discard_after_completion }{
        .write_failure, .seal_failure, .discard, .discard_after_completion,
    }, 0..) |scenario, index| {
        var name_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "capture-{d}", .{index});
        const created = try tmp.dir.createFile(std.testing.io, name, .{ .read = true });
        const file = if (scenario == .write_failure) blk: {
            created.close(std.testing.io);
            break :blk try tmp.dir.openFile(std.testing.io, name, .{});
        } else created;
        const readonly = try tmp.dir.openFile(std.testing.io, name, .{});
        try tmp.dir.deleteFile(std.testing.io, name);
        var transfer: Transfer = undefined;
        transfer.writer = &writer;
        transfer.response = .{
            .io = std.testing.io,
            .file = file,
            .readonly = readonly,
            .budget = .{ .used = &used, .limit = 100 },
        };
        transfer.local = .receiving;
        transfer.in_reactor = false;
        try std.testing.expectEqual(@as(usize, 3), writer.offer(&transfer.response, "xyz"));
        try std.testing.expectEqual(@as(u64, 44), used.load(.acquire));
        if (scenario == .discard or scenario == .discard_after_completion) {
            if (scenario == .discard_after_completion) {
                transfer.finish(.{ .transport_finished = .{ .disposition = .success } }, 0);
                try std.testing.expect(transfer.advanceFinalization(false) == .pending);
                try std.testing.expectEqual(@as(usize, 2), writer.count);
            }
            transfer.discard();
            try std.testing.expect(transfer.advanceFinalization(false) == .pending);
        } else {
            transfer.finish(.{ .transport_finished = .{ .disposition = .success } }, 0);
            try std.testing.expect(transfer.advanceFinalization(scenario == .seal_failure) == .pending);
        }
        writer.mutex.lockUncancelable(writer.io);
        writer.processOne();
        if (scenario == .write_failure) {
            try std.testing.expectEqual(CaptureFailure.write_failed, transfer.captureFailure().?);
            try std.testing.expectEqual(@as(u64, 0), transfer.response.length);
        }
        if (scenario != .discard) {
            try std.testing.expectEqual(@as(usize, 1), transfer.response.pending_writes);
            try std.testing.expect(transfer.advanceFinalization(true) == .pending);
            writer.mutex.lockUncancelable(writer.io);
            writer.processOne();
        }
        if (scenario == .discard_after_completion) try std.testing.expect(transfer.response.sealed);
        const final = transfer.advanceFinalization(false);
        switch (scenario) {
            .discard, .discard_after_completion => try std.testing.expect(final == .discarded),
            .write_failure => try std.testing.expect(final == .ready and final.ready.outcome == .response_capture_failed and final.ready.outcome.response_capture_failed == .write_failed),
            .seal_failure => try std.testing.expect(final == .ready and final.ready.outcome == .response_capture_failed and final.ready.outcome.response_capture_failed == .seal_failed),
        }
        try std.testing.expectEqual(@as(usize, 0), writer.count);
        transfer.response.deinit();
        try std.testing.expectEqual(@as(u64, 41), used.load(.acquire));
    }
}

test "real preparation consumes the configured allowance across multiple advances" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [protocol.max_store_bytes]u8 = undefined;
    const root_length = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
    const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{root});
    var storage = try store.Store.open(std.testing.io, database, root);
    defer storage.close() catch unreachable;

    var workspace_buffer: [protocol.max_workspace_bytes]u8 = undefined;
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
    defer directory.close(std.testing.io);
    const workspace = workspace_buffer[0..try directory.realPath(std.testing.io, &workspace_buffer)];
    var configuration: protocol.ConfigureCommand = .{};
    try configuration.key.set("prep-config");
    try configuration.session.set("direct/prep");
    configuration.configuration.workspace.state = .value;
    try configuration.configuration.workspace.value.set(workspace);
    configuration.configuration.provider.state = .value;
    try configuration.configuration.provider.value.set("codex");
    configuration.configuration.model.state = .value;
    try configuration.configuration.model.value.set("model-a");
    try std.testing.expect(storage.configure(&configuration, .{}) == .accepted);

    const text = "x" ** 80;
    const file = try tmp.dir.createFile(std.testing.io, "prep-file", .{ .read = true });
    try file.writeStreamingAll(std.testing.io, text);
    try file.sync(std.testing.io);
    var message: protocol.MessageCommand = .{};
    try message.key.set("prep-message");
    try message.session.set("direct/prep");
    message.text = .{
        .state = .value,
        .file = file,
        .length = text.len,
        .digest = protocol.contentDigest(text),
    };
    defer message.removeTemporaryContent(std.testing.io) catch unreachable;
    try std.testing.expect(storage.submitMessage(&message, .{}) == .accepted);

    var admitted = (try storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();
    const view = try storage.openHistoricalView(binding);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var preparation: Preparation = undefined;
    try preparation.init(
        std.testing.io,
        view,
        root,
        .{ .used = &used, .limit = 4096 },
        .{},
        &retained,
    );
    defer if (preparation.active) preparation.cancel();
    var advances: usize = 0;
    var last_request: u64 = 0;
    while (true) {
        advances += 1;
        try std.testing.expect(advances < 64);
        var progress = preparation.advance(16, 2);
        const stats = preparation.advanceStats();
        try std.testing.expect(stats.work_bytes <= 16);
        try std.testing.expect(stats.work_items <= 2);
        try std.testing.expect(stats.request_bytes >= last_request);
        last_request = stats.request_bytes;
        switch (progress) {
            .pending => {},
            .prepared => |*request| {
                try std.testing.expect(advances > 1);
                try std.testing.expect(request.length > 0);
                request.deinit();
                return;
            },
            .failed => |err| return err,
        }
    }
}

test "plain JSON runs batch writes and conserve scan plus output allowance" {
    const Sink = struct {
        calls: usize = 0,
        bytes: usize = 0,
        pub fn write(self: *@This(), value: []const u8) !void {
            self.calls += 1;
            self.bytes += value.len;
        }
    };
    const text = "x" ** (256 * 1024);
    var sink: Sink = .{};
    var position: usize = 0;
    while (position != text.len) {
        var allowance: usize = preparation_byte_allowance;
        const count = try writePlainJsonRun(&sink, text[position..], &allowance);
        try std.testing.expect(count != 0);
        try std.testing.expectEqual(preparation_byte_allowance, allowance + 2 * count);
        position += count;
    }
    try std.testing.expectEqual(text.len, sink.bytes);
    try std.testing.expectEqual(@as(usize, 32), sink.calls);
    var one: usize = 1;
    try std.testing.expectEqual(@as(usize, 0), try writePlainJsonRun(&sink, "x", &one));
    try std.testing.expectEqual(@as(usize, 1), one);
    try std.testing.expectEqual(@as(usize, 32), sink.calls);
    var escaped: usize = 20;
    try std.testing.expectEqual(@as(usize, 3), try writePlainJsonRun(&sink, "abc\"def", &escaped));
    try std.testing.expectEqual(@as(usize, 14), escaped);
    try std.testing.expectEqual(@as(usize, 0), try writePlainJsonRun(&sink, "\n", &escaped));
    try std.testing.expectEqual(@as(usize, 0), try writePlainJsonRun(&sink, "\\", &escaped));
}

const PreparationTestSetup = struct {
    tmp: std.testing.TmpDir,
    storage: store.Store,
    root: []const u8,
    root_buffer: [protocol.max_store_bytes]u8,
    workspace_buffer: [protocol.max_workspace_bytes]u8,
    workspace: []const u8,

    fn init(self: *PreparationTestSetup) !void {
        self.* = .{
            .tmp = std.testing.tmpDir(.{}),
            .storage = undefined,
            .root = undefined,
            .root_buffer = undefined,
            .workspace_buffer = undefined,
            .workspace = undefined,
        };
        errdefer self.tmp.cleanup();
        const root_length = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        self.root = self.root_buffer[0..root_length];
        var database_buffer: [platform.max_database_path_bytes]u8 = undefined;
        const database = try std.fmt.bufPrint(&database_buffer, "{s}/store.sqlite3", .{self.root});
        self.storage = try store.Store.open(std.testing.io, database, self.root);
        errdefer self.storage.close() catch unreachable;
        var directory = try std.Io.Dir.cwd().openDir(std.testing.io, ".", .{});
        defer directory.close(std.testing.io);
        self.workspace = self.workspace_buffer[0..try directory.realPath(std.testing.io, &self.workspace_buffer)];
    }

    fn close(self: *PreparationTestSetup) void {
        self.storage.close() catch unreachable;
        self.tmp.cleanup();
    }

    fn configure(self: *PreparationTestSetup, key: []const u8, session: []const u8) !void {
        var command: protocol.ConfigureCommand = .{};
        try command.key.set(key);
        try command.session.set(session);
        command.configuration.workspace.state = .value;
        try command.configuration.workspace.value.set(self.workspace);
        command.configuration.provider.state = .value;
        try command.configuration.provider.value.set("codex");
        command.configuration.model.state = .value;
        try command.configuration.model.value.set("model-a");
        try std.testing.expect(self.storage.configure(&command, .{}) == .accepted);
    }

    fn submit(self: *PreparationTestSetup, file_name: []const u8, key: []const u8, session: []const u8, text: []const u8) !void {
        const file = try self.tmp.dir.createFile(std.testing.io, file_name, .{ .read = true });
        try file.writeStreamingAll(std.testing.io, text);
        try file.sync(std.testing.io);
        var command: protocol.MessageCommand = .{};
        try command.key.set(key);
        try command.session.set(session);
        command.text = .{
            .state = .value,
            .file = file,
            .length = text.len,
            .digest = protocol.contentDigest(text),
        };
        defer command.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(self.storage.submitMessage(&command, .{}) == .accepted);
    }
};

const DrainedRequest = struct { bytes: []u8, length: u64, digest: [32]u8 };

// Independently authored tool definitions for full-request goldens. These
// literals must match the provider's frozen tool catalog, not reference it.
const bash_tool_json = "{\"type\":\"function\",\"name\":\"bash\",\"description\":\"Run Bash\",\"strict\":true,\"parameters\":{\"type\":\"object\",\"properties\":{\"cmd\":{\"type\":\"string\"},\"timeout_ms\":{\"type\":[\"integer\",\"null\"],\"minimum\":1,\"maximum\":9223372036854775807}},\"required\":[\"cmd\",\"timeout_ms\"],\"additionalProperties\":false}}";
const edit_tool_json = "{\"type\":\"function\",\"name\":\"edit\",\"description\":\"Edit one file\"}";

fn drainPreparation(
    preparation: *Preparation,
    byte_allowance: usize,
    item_allowance: usize,
    step_bound: usize,
) !DrainedRequest {
    var request = try drainLivePreparation(preparation, byte_allowance, item_allowance, step_bound);
    defer request.deinit();
    const length: usize = @intCast(request.length);
    const bytes = try std.testing.allocator.alloc(u8, length);
    errdefer std.testing.allocator.free(bytes);
    const actual = try request.file.readPositionalAll(request.io, bytes, 0);
    try std.testing.expectEqual(length, actual);
    try std.testing.expectEqual(request.length, try request.file.length(request.io));
    const digest = protocol.contentDigest(bytes);
    return .{ .bytes = bytes, .length = request.length, .digest = digest };
}

/// Drain to a live PreparedRequest the caller owns across later Store
/// changes. The request stays readable until the caller releases it. The
/// step bound limits completed advances, not attempted ones: a trip on the
/// sealing advance still acquires its request first, so the terminal-result
/// guard below must release it before the bound error escapes.
fn drainLivePreparation(
    preparation: *Preparation,
    byte_allowance: usize,
    item_allowance: usize,
    step_bound: usize,
) !PreparedRequest {
    var steps: usize = 0;
    var last_request: u64 = 0;
    while (true) {
        steps += 1;
        var progress = preparation.advance(byte_allowance, item_allowance);
        // Guard an owning terminal result adjacent to acquisition, before
        // any fallible assertion below can drop it.
        switch (progress) {
            .pending => {
                try std.testing.expect(steps <= step_bound);
                const stats = preparation.advanceStats();
                try std.testing.expect(stats.work_bytes <= byte_allowance);
                try std.testing.expect(stats.work_items <= item_allowance);
                try std.testing.expect(stats.request_bytes >= last_request);
                last_request = stats.request_bytes;
                try std.testing.expect(preparation.active);
            },
            .prepared => |*request| {
                var transferred = false;
                errdefer if (!transferred) request.deinit();
                try std.testing.expect(steps <= step_bound);
                const stats = preparation.advanceStats();
                try std.testing.expect(stats.work_bytes <= byte_allowance);
                try std.testing.expect(stats.work_items <= item_allowance);
                try std.testing.expect(stats.request_bytes >= last_request);
                try std.testing.expect(!preparation.active);
                transferred = true;
                return request.*;
            },
            .failed => |err| {
                try std.testing.expect(steps <= step_bound);
                const stats = preparation.advanceStats();
                try std.testing.expect(stats.work_bytes <= byte_allowance);
                try std.testing.expect(stats.work_items <= item_allowance);
                try std.testing.expect(stats.request_bytes >= last_request);
                return err;
            },
        }
    }
}

/// Step a fresh preparation with (1, 1) allowances until exactly `target`
/// request bytes exist, then return with the emission still in progress.
/// The writer only appends, so a target strictly inside a known emission
/// span guarantees that emission's content reader is still open.
fn stepPreparationToOffset(preparation: *Preparation, target: u64, step_bound: usize) !void {
    var steps: usize = 0;
    while (true) {
        steps += 1;
        try std.testing.expect(steps <= step_bound);
        var progress = preparation.advance(1, 1);
        switch (progress) {
            .pending => {},
            // An unexpectedly sealed request is owned here: release it
            // before reporting the failed expectation so a statistics or
            // offset regression cannot leak the descriptor. The preparation
            // is inactive after sealing, so callers must not cancel it.
            .prepared => |*request| {
                request.deinit();
                try std.testing.expect(false);
                unreachable;
            },
            .failed => |err| return err,
        }
        const written = preparation.advanceStats().request_bytes;
        if (written == target) return;
        try std.testing.expect(written < target);
    }
}

const ComposedCall = struct {
    item_id: []const u8,
    call_id: []const u8,
};

/// Settle one reasoning item plus valid Bash calls in a single model
/// success, so the successor's historical view holds replay input and a
/// complete Tool Result group from ordinary Store transitions. Call items
/// are stored as complete item JSON exactly like provider validation
/// stores them, so replay copies them verbatim.
fn settleComposedForTesting(
    setup: *PreparationTestSetup,
    binding: store.AttemptBinding,
    file_prefix: []const u8,
    reasoning_json: []const u8,
    calls: []const ComposedCall,
) !void {
    const decoded_arguments = "{\"cmd\":\"true\",\"timeout_ms\":null}";
    const encoded_arguments = "{\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}";
    var source_buffer: [64 * 1024]u8 = undefined;
    var source_writer = std.Io.Writer.fixed(&source_buffer);
    try source_writer.writeAll(reasoning_json);
    var metadata_used: std.atomic.Value(u64) = .init(0);
    var retained_metadata: ?named_scratch.Owner = null;
    var metadata = try store.OutputMetadataWriter.init(
        std.testing.io,
        setup.root,
        file_prefix,
        .{ .used = &metadata_used, .limit = (1 + 5 * calls.len) * 104 },
        false,
        &retained_metadata,
    );
    defer metadata.deinit();
    try metadata.append(.{
        .tag = .item,
        .kind = .reasoning,
        .ordinal = 0,
        .start = 0,
        .length = reasoning_json.len,
        .content_digest = protocol.contentDigest(reasoning_json),
    });
    var offset: u64 = reasoning_json.len;
    for (calls, 0..) |call, index| {
        const ordinal = index + 1;
        const item_start: usize = @intCast(offset);
        // Full item JSON; string ranges address inner bytes (no quotes)
        // with digests over the decoded values.
        try source_writer.writeAll("{\"type\":\"function_call\",\"id\":\"");
        const id_start: u64 = offset + @as(u64, @intCast(source_writer.buffered().len - item_start));
        try source_writer.writeAll(call.item_id);
        const id_end: u64 = offset + @as(u64, @intCast(source_writer.buffered().len - item_start));
        try source_writer.writeAll("\",\"status\":\"completed\",\"name\":\"");
        const name_start: u64 = offset + @as(u64, @intCast(source_writer.buffered().len - item_start));
        try source_writer.writeAll("bash");
        const name_end: u64 = offset + @as(u64, @intCast(source_writer.buffered().len - item_start));
        try source_writer.writeAll("\",\"call_id\":\"");
        const call_start: u64 = offset + @as(u64, @intCast(source_writer.buffered().len - item_start));
        try source_writer.writeAll(call.call_id);
        const call_end: u64 = offset + @as(u64, @intCast(source_writer.buffered().len - item_start));
        try source_writer.writeAll("\",\"arguments\":\"");
        const args_start: u64 = offset + @as(u64, @intCast(source_writer.buffered().len - item_start));
        try source_writer.writeAll(encoded_arguments);
        const args_end: u64 = offset + @as(u64, @intCast(source_writer.buffered().len - item_start));
        try source_writer.writeAll("\"}");
        offset += @as(u64, @intCast(source_writer.buffered().len - item_start));
        const item_bytes = source_writer.buffered()[item_start..];
        try metadata.append(.{
            .tag = .item_id,
            .kind = .function_call,
            .ordinal = ordinal,
            .start = id_start,
            .length = id_end - id_start,
            .decoded_length = call.item_id.len,
            .content_digest = protocol.contentDigest(call.item_id),
        });
        try metadata.append(.{
            .tag = .name,
            .kind = .function_call,
            .ordinal = ordinal,
            .start = name_start,
            .length = name_end - name_start,
            .decoded_length = "bash".len,
            .content_digest = protocol.contentDigest("bash"),
        });
        try metadata.append(.{
            .tag = .call_id,
            .kind = .function_call,
            .ordinal = ordinal,
            .start = call_start,
            .length = call_end - call_start,
            .decoded_length = call.call_id.len,
            .content_digest = protocol.contentDigest(call.call_id),
        });
        try metadata.append(.{
            .tag = .arguments,
            .kind = .function_call,
            .ordinal = ordinal,
            .start = args_start,
            .length = args_end - args_start,
            .decoded_length = decoded_arguments.len,
            .content_digest = protocol.contentDigest(decoded_arguments),
        });
        try metadata.append(.{
            .tag = .item,
            .kind = .function_call,
            .ordinal = ordinal,
            .start = item_start,
            .length = item_bytes.len,
            .id_digest = protocol.contentDigest(call.item_id),
            .content_digest = protocol.contentDigest(item_bytes),
        });
    }
    try metadata.sealForRead();
    const source_bytes = source_writer.buffered();
    var source_name: [64]u8 = undefined;
    const source = try setup.tmp.dir.createFile(std.testing.io, try std.fmt.bufPrint(&source_name, "{s}-source", .{file_prefix}), .{ .read = true });
    defer source.close(std.testing.io);
    try source.writeStreamingAll(std.testing.io, source_bytes);
    try source.sync(std.testing.io);
    try setup.storage.settleModelSuccess(binding, &.{
        .source = source,
        .source_length = source_bytes.len,
        .metadata = metadata.file,
        .item_count = 1 + calls.len,
        .call_count = calls.len,
        .answer_length = 0,
        .answer_digest = protocol.contentDigest(""),
        .response_id = .{},
        .body_model = .{},
        .openai_model = .{},
        .x_openai_model = .{},
        .request_id = .{},
    }, .{});
}

/// Build one reasoning item plus two valid Bash calls, deny both Actions
/// in reverse call order, and admit the successor whose historical view
/// must derive Tool Results in original call order.
fn establishComposedHistory(setup: *PreparationTestSetup, session: []const u8) !store.AttemptBinding {
    const schema_json = "{\"type\":\"object\"}";
    {
        const file = try setup.tmp.dir.createFile(std.testing.io, "composed-schema", .{ .read = true });
        try file.writeStreamingAll(std.testing.io, schema_json);
        try file.sync(std.testing.io);
        var command: protocol.ConfigureCommand = .{};
        try command.key.set("composed-config");
        try command.session.set(session);
        command.configuration.workspace.state = .value;
        try command.configuration.workspace.value.set(setup.workspace);
        command.configuration.provider.state = .value;
        try command.configuration.provider.value.set("codex");
        command.configuration.model.state = .value;
        try command.configuration.model.value.set("model-a");
        command.configuration.output_schema = .{
            .state = .value,
            .file = file,
            .length = schema_json.len,
            .digest = protocol.contentDigest(schema_json),
        };
        defer command.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(setup.storage.configure(&command, .{}) == .accepted);
    }
    try setup.submit("composed-message-file", "composed-message", session, "do work");
    var admitted = (try setup.storage.admitNextModelAttempt(.{})).?;
    const source_binding = try admitted.permit.consume();
    const reasoning_json = "{\"type\":\"reasoning\",\"id\":\"r1\",\"created_by\":\"drop-me\",\"encrypted_content\":\"opaque\"}";
    const calls = [_]ComposedCall{
        .{ .item_id = "order-item-a", .call_id = "order-call-a" },
        .{ .item_id = "order-item-b", .call_id = "order-call-b" },
    };
    try settleComposedForTesting(setup, source_binding, "composed-metadata", reasoning_json, &calls);
    var second_deny: protocol.PermissionDecisionCommand = .{ .action_id = 2 };
    try second_deny.key.set("composed-deny-second");
    try second_deny.session.set(session);
    try std.testing.expect(setup.storage.denyPermission(&second_deny, .{}) == .accepted);
    var first_deny: protocol.PermissionDecisionCommand = .{ .action_id = 1 };
    try first_deny.key.set("composed-deny-first");
    try first_deny.session.set(session);
    try std.testing.expect(setup.storage.denyPermission(&first_deny, .{}) == .accepted);
    var successor = (try setup.storage.admitNextModelAttempt(.{})) orelse return error.ExpectedSuccessorAdmission;
    return successor.permit.consume();
}

const composed_replayed = "{\"type\":\"reasoning\",\"id\":\"r1\",\"encrypted_content\":\"opaque\"}";

// Replayed call items appear verbatim: they carry no top-level
// response-only fields. Written separately from the settle helper so the
// golden does not share its construction.
const composed_replayed_call_a = "{\"type\":\"function_call\",\"id\":\"order-item-a\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"order-call-a\",\"arguments\":\"{\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}\"}";
const composed_replayed_call_b = "{\"type\":\"function_call\",\"id\":\"order-item-b\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"order-call-b\",\"arguments\":\"{\\\"cmd\\\":\\\"true\\\",\\\"timeout_ms\\\":null}\"}";

const composed_expected =
    "{\"model\":\"model-a\",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"input\":[" ++
    "{\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":\"\"}]}," ++
    "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"do work\"}]}," ++
    composed_replayed ++ "," ++
    composed_replayed_call_a ++ "," ++
    composed_replayed_call_b ++ "," ++
    "{\"type\":\"function_call_output\",\"call_id\":\"order-call-a\",\"output\":\"Permission denied.\"}," ++
    "{\"type\":\"function_call_output\",\"call_id\":\"order-call-b\",\"output\":\"Permission denied.\"}]," ++
    "\"tools\":[" ++ bash_tool_json ++ "," ++ edit_tool_json ++ "]," ++
    "\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"rui_output\",\"strict\":true,\"schema\":{\"type\":\"object\"}}}}";

test "request preparation minimal golden is exact across schedules" {
    const expected = "{\"model\":\"model-a\",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"input\":[{\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":\"\"}]},{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}]";
    const full_expected = expected ++ ",\"tools\":[]}";
    const schedules = [_][2]usize{ .{ 16, 2 }, .{ 1, 1 }, .{ 16384, 64 }, .{ 7, 3 } };
    var first_bytes: ?[]u8 = null;
    defer if (first_bytes) |bytes| std.testing.allocator.free(bytes);
    for (schedules, 0..) |schedule, index| {
        // Each schedule prepares identical logical content through an
        // independent Store so later admissions cannot observe earlier ones.
        var setup: PreparationTestSetup = undefined;
        try setup.init();
        defer setup.close();
        try setup.configure("prep-golden-config", "direct/prep-golden");
        // Explicit empty tool list selects no tools for an exact small envelope.
        {
            var update: protocol.ConfigureCommand = .{};
            try update.key.set("prep-golden-tools");
            try update.session.set("direct/prep-golden");
            update.configuration.tools.state = .value;
            update.configuration.tools.count = 0;
            try std.testing.expect(setup.storage.configure(&update, .{}) == .accepted);
        }
        var file_name: [32]u8 = undefined;
        const file = try std.fmt.bufPrint(&file_name, "prep-golden-file-{d}", .{index});
        var key: [32]u8 = undefined;
        const message_key = try std.fmt.bufPrint(&key, "prep-golden-message-{d}", .{index});
        try setup.submit(file, message_key, "direct/prep-golden", "hi");
        var admitted = (try setup.storage.admitNextModelAttempt(.{})).?;
        const binding = try admitted.permit.consume();
        const view = try setup.storage.openHistoricalView(binding);
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        var preparation: Preparation = undefined;
        try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
        try std.testing.expect(retained == null);
        const result = try drainPreparation(&preparation, schedule[0], schedule[1], 4096);
        defer std.testing.allocator.free(result.bytes);
        try std.testing.expectEqualStrings(full_expected, result.bytes);
        try std.testing.expectEqual(@as(u64, full_expected.len), result.length);
        try std.testing.expectEqual(protocol.contentDigest(full_expected), result.digest);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        if (first_bytes == null) {
            first_bytes = try std.testing.allocator.dupe(u8, result.bytes);
        } else {
            try std.testing.expectEqualStrings(first_bytes.?, result.bytes);
        }
    }
}

test "request preparation escapes instructions and user content" {
    var setup: PreparationTestSetup = undefined;
    try setup.init();
    defer setup.close();
    const instructions_text = "a\"b\\c\n\x01d";
    const user_text = "u\"v\\w\x7fé";
    {
        const file = try setup.tmp.dir.createFile(std.testing.io, "prep-escape-instructions", .{ .read = true });
        try file.writeStreamingAll(std.testing.io, instructions_text);
        try file.sync(std.testing.io);
        var command: protocol.ConfigureCommand = .{};
        try command.key.set("prep-escape-config");
        try command.session.set("direct/prep-escape");
        command.configuration.workspace.state = .value;
        try command.configuration.workspace.value.set(setup.workspace);
        command.configuration.provider.state = .value;
        try command.configuration.provider.value.set("codex");
        command.configuration.model.state = .value;
        try command.configuration.model.value.set("model-a");
        command.configuration.instructions = .{
            .state = .value,
            .file = file,
            .length = instructions_text.len,
            .digest = protocol.contentDigest(instructions_text),
        };
        defer command.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(setup.storage.configure(&command, .{}) == .accepted);
    }
    try setup.submit("prep-escape-file", "prep-escape-message", "direct/prep-escape", user_text);

    var admission = (try setup.storage.admitNextModelAttempt(.{})).?;
    const binding = try admission.permit.consume();
    const view = try setup.storage.openHistoricalView(binding);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var preparation: Preparation = undefined;
    try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
    const first = try drainPreparation(&preparation, 2, 2, 4096);
    defer std.testing.allocator.free(first.bytes);
    try setup.storage.settleModelAttemptFailure(binding, "prep_escape_release", .terminal, .{});

    // Independent escape expectations: quotes, backslashes, newline and
    // control bytes use short or \u00xx forms; UTF-8 bytes pass through.
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "a\\\"b\\\\c\\n\\u0001d") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, "u\\\"v\\\\w\x7fé") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.bytes, instructions_text) == null);

    _ = (try setup.storage.admitNextModelAttempt(.{}));
    // The terminal settlement above leaves no resumable work; re-establish a
    // second session carrying the same bytes to check schedule equality.
    var setup_two: PreparationTestSetup = undefined;
    try setup_two.init();
    defer setup_two.close();
    {
        const file = try setup_two.tmp.dir.createFile(std.testing.io, "prep-escape2-instructions", .{ .read = true });
        try file.writeStreamingAll(std.testing.io, instructions_text);
        try file.sync(std.testing.io);
        var command: protocol.ConfigureCommand = .{};
        try command.key.set("prep-escape2-config");
        try command.session.set("direct/prep-escape2");
        command.configuration.workspace.state = .value;
        try command.configuration.workspace.value.set(setup_two.workspace);
        command.configuration.provider.state = .value;
        try command.configuration.provider.value.set("codex");
        command.configuration.model.state = .value;
        try command.configuration.model.value.set("model-a");
        command.configuration.instructions = .{
            .state = .value,
            .file = file,
            .length = instructions_text.len,
            .digest = protocol.contentDigest(instructions_text),
        };
        defer command.removeTemporaryContent(std.testing.io) catch unreachable;
        try std.testing.expect(setup_two.storage.configure(&command, .{}) == .accepted);
    }
    try setup_two.submit("prep-escape2-file", "prep-escape2-message", "direct/prep-escape2", user_text);
    var admitted_two = (try setup_two.storage.admitNextModelAttempt(.{})).?;
    const binding_two = try admitted_two.permit.consume();
    const view_two = try setup_two.storage.openHistoricalView(binding_two);
    var used_two: std.atomic.Value(u64) = .init(0);
    var retained_two: ?named_scratch.Owner = null;
    var preparation_two: Preparation = undefined;
    try preparation_two.init(std.testing.io, view_two, setup_two.root, .{ .used = &used_two, .limit = 8 * 1024 * 1024 }, .{}, &retained_two);
    const second = try drainPreparation(&preparation_two, 1, 1, 8192);
    defer std.testing.allocator.free(second.bytes);
    try std.testing.expectEqualStrings(first.bytes, second.bytes);
}

test "request preparation frozen selection excludes later messages" {
    var setup: PreparationTestSetup = undefined;
    try setup.init();
    defer setup.close();
    try setup.configure("prep-frozen-config", "direct/prep-frozen");
    try setup.submit("prep-frozen-first-file", "prep-frozen-first", "direct/prep-frozen", "first");
    var admitted = (try setup.storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();
    const view = try setup.storage.openHistoricalView(binding);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var preparation: Preparation = undefined;
    try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
    // Advance partially, then submit a later message while the admitted
    // historical view stays frozen.
    var partial: usize = 0;
    while (partial < 2) : (partial += 1) {
        const progress = preparation.advance(16, 2);
        try std.testing.expect(progress == .pending);
    }
    try setup.submit("prep-frozen-second-file", "prep-frozen-second", "direct/prep-frozen", "second");
    const result = try drainPreparation(&preparation, 16, 2, 4096);
    defer std.testing.allocator.free(result.bytes);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "second") == null);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "request preparation freezes settings at admission" {
    var setup: PreparationTestSetup = undefined;
    try setup.init();
    defer setup.close();
    try setup.configure("prep-settings-config", "direct/prep-settings");
    try setup.submit("prep-settings-file", "prep-settings-message", "direct/prep-settings", "hi");
    var admitted = (try setup.storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();
    // A legal observable change after admission but before preparation
    // first reads settings: the admitted view must keep the original
    // Bash/Edit catalog, not the current empty tool list.
    {
        var update: protocol.ConfigureCommand = .{};
        try update.key.set("prep-settings-tools");
        try update.session.set("direct/prep-settings");
        update.configuration.tools.state = .value;
        update.configuration.tools.count = 0;
        try std.testing.expect(setup.storage.configure(&update, .{}) == .accepted);
    }
    const view = try setup.storage.openHistoricalView(binding);
    var used: std.atomic.Value(u64) = .init(0);
    var retained: ?named_scratch.Owner = null;
    var preparation: Preparation = undefined;
    try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
    const result = try drainPreparation(&preparation, 3, 2, 8192);
    defer std.testing.allocator.free(result.bytes);
    const expected = "{\"model\":\"model-a\",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"input\":[{\"role\":\"system\",\"content\":[{\"type\":\"input_text\",\"text\":\"\"}]},{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}],\"tools\":[" ++
        bash_tool_json ++ "," ++ edit_tool_json ++ "]}";
    try std.testing.expectEqualStrings(expected, result.bytes);
    try std.testing.expectEqual(@as(u64, expected.len), result.length);
    try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
}

test "preparation integrity follows live readers and rejects a foreign binding" {
    var setup: PreparationTestSetup = undefined;
    try setup.init();
    defer setup.close();
    try setup.configure("prep-integrity-config", "direct/prep-integrity");
    const text = "y" ** 512;
    try setup.submit("prep-integrity-file", "prep-integrity-message", "direct/prep-integrity", text);
    var admitted = (try setup.storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();

    const view = try setup.storage.openHistoricalView(binding);
    var used: std.atomic.Value(u64) = .init(41);
    const baseline = used.load(.acquire);
    var retained: ?named_scratch.Owner = null;
    var preparation: Preparation = undefined;
    try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
    // Guard the active preparation separately from any sealed request: a
    // sealed preparation is inactive, so this guard never cancels a
    // transferred owner.
    defer if (preparation.active) preparation.cancel();
    // Fresh preparation: active view, admitted binding, no open readers.
    try preparation.checkIntegrity(binding);
    try std.testing.expectEqual(@as(usize, 0), preparation.view.outstandingReaders());
    const address_before = @intFromPtr(&preparation);

    // Step inside the user-content emission with the same probe pattern the
    // cancellation test uses, so the content reader is necessarily open.
    var probe: Preparation = undefined;
    {
        const probe_view = try setup.storage.openHistoricalView(binding);
        var probe_used: std.atomic.Value(u64) = .init(0);
        var probe_retained: ?named_scratch.Owner = null;
        try probe.init(std.testing.io, probe_view, setup.root, .{ .used = &probe_used, .limit = 8 * 1024 * 1024 }, .{}, &probe_retained);
        defer if (probe.active) probe.cancel();
        const probe_result = try drainPreparation(&probe, 16, 2, 16384);
        defer std.testing.allocator.free(probe_result.bytes);
        const content_start = std.mem.indexOf(u8, probe_result.bytes, text).?;
        try stepPreparationToOffset(&preparation, content_start + 100, 16384);
    }
    // The owner stayed at its address while borrowed; one live reader.
    try std.testing.expectEqual(address_before, @intFromPtr(&preparation));
    try std.testing.expectEqual(@as(usize, 1), preparation.view.outstandingReaders());
    try preparation.checkIntegrity(binding);

    // A foreign binding is rejected without disturbing the live owner.
    const foreign = store.AttemptBinding{
        .turn_id = binding.turn_id,
        .operation_id = binding.operation_id + 1,
        .attempt_ordinal = binding.attempt_ordinal,
    };
    try std.testing.expectError(error.PreparationBindingMismatch, preparation.checkIntegrity(foreign));
    try preparation.checkIntegrity(binding);

    // An extra outstanding reader breaks the count the emission accounts for.
    // The reader lives in a nested scope so it closes before preparation
    // cancellation on both success and error paths.
    {
        var extra = try preparation.view.openContent(preparation.settings.?.baseline_instructions);
        defer extra.close();
        try std.testing.expectError(error.PreparationReaderCountMismatch, preparation.checkIntegrity(binding));
    }
    try preparation.checkIntegrity(binding);

    try std.testing.expect(used.load(.acquire) > baseline);
    preparation.cancel();
    try std.testing.expect(!preparation.active);
    try std.testing.expectError(error.PreparationInactive, preparation.checkIntegrity(binding));
    try std.testing.expectEqual(baseline, used.load(.acquire));
    try std.testing.expect(retained == null);
}

test "request preparation cancellation and failure release ownership" {
    var setup: PreparationTestSetup = undefined;
    try setup.init();
    defer setup.close();
    try setup.configure("prep-owner-config", "direct/prep-owner");
    const text = "x" ** 512;
    try setup.submit("prep-owner-file", "prep-owner-message", "direct/prep-owner", text);
    var admitted = (try setup.storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();

    // Cancel inside the user-content JSON emission: the target lies
    // strictly inside the written user bytes, so the content reader is
    // necessarily still open and a partial charge is outstanding. Reader
    // closure before view closure is enforced by the close-path asserts;
    // cancellation must return usage to the starting baseline.
    {
        const view = try setup.storage.openHistoricalView(binding);
        var used: std.atomic.Value(u64) = .init(7);
        const baseline = used.load(.acquire);
        var retained: ?named_scratch.Owner = null;
        var preparation: Preparation = undefined;
        try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
        defer if (preparation.active) preparation.cancel();
        var probe: Preparation = undefined;
        {
            const probe_view = try setup.storage.openHistoricalView(binding);
            var probe_used: std.atomic.Value(u64) = .init(0);
            var probe_retained: ?named_scratch.Owner = null;
            try probe.init(std.testing.io, probe_view, setup.root, .{ .used = &probe_used, .limit = 8 * 1024 * 1024 }, .{}, &probe_retained);
            defer if (probe.active) probe.cancel();
            const probe_result = try drainPreparation(&probe, 16, 2, 16384);
            defer std.testing.allocator.free(probe_result.bytes);
            const content_start = std.mem.indexOf(u8, probe_result.bytes, text).?;
            try stepPreparationToOffset(&preparation, content_start + 100, 16384);
        }
        // Direct owner prerequisites, not just the target offset: the
        // intended reader is active and a reservation is outstanding.
        try preparation.checkIntegrity(binding);
        try std.testing.expectEqual(@as(usize, 1), preparation.view.outstandingReaders());
        try std.testing.expect(used.load(.acquire) > baseline);
        preparation.cancel();
        try std.testing.expect(!preparation.active);
        try std.testing.expectEqual(baseline, used.load(.acquire));
        try std.testing.expect(retained == null);
    }

    // First-step initialization failure owns nothing.
    {
        const view = try setup.storage.openHistoricalView(binding);
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        var preparation: Preparation = undefined;
        try std.testing.expectError(error.InjectedFirstPreparationFailure, preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{ .first_step = true }, &retained));
        try std.testing.expect(retained == null);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }

    // Write and seal faults surface through advance and release on cancel.
    for ([_]PreparationFaults{ .{ .write = true }, .{ .seal = true } }) |faults| {
        const view = try setup.storage.openHistoricalView(binding);
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        var preparation: Preparation = undefined;
        try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, faults, &retained);
        var seen_failure: ?anyerror = null;
        var steps: usize = 0;
        while (steps < 4096) : (steps += 1) {
            var progress = preparation.advance(64, 8);
            switch (progress) {
                .pending => {},
                .prepared => |*request| {
                    request.deinit();
                    break;
                },
                .failed => |err| {
                    seen_failure = err;
                    break;
                },
            }
        }
        try std.testing.expect(seen_failure != null);
        // Failed writes retain the complete reservation, which may exceed the
        // successfully written prefix; cancellation still releases it once.
        preparation.cancel();
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }

    // Unlink faults retain actionable custody until reclamation is
    // confirmed; clearing the test-owned gate completes the same
    // production reclamation path without leaking the descriptors.
    {
        const view = try setup.storage.openHistoricalView(binding);
        var used: std.atomic.Value(u64) = .init(0);
        var gate: std.atomic.Value(bool) = .init(true);
        var retained: ?named_scratch.Owner = null;
        var preparation: Preparation = undefined;
        try std.testing.expectError(error.InjectedRequestUnlinkFailure, preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{ .unlink = true, .unlink_removal = &gate }, &retained));
        try std.testing.expect(retained != null);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        var reclaimed = false;
        defer {
            if (!reclaimed) {
                gate.store(false, .release);
                _ = retained.?.reclaim(setup.root) catch .removed;
            }
        }
        try std.testing.expectError(error.InjectedScratchRemovalFailure, retained.?.reclaim(setup.root));
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        gate.store(false, .release);
        // Record consuming reclamation before asserting the observation, so
        // a failed expectation cannot retry an already-consumed owner.
        const reclamation = try retained.?.reclaim(setup.root);
        reclaimed = true;
        try std.testing.expectEqual(named_scratch.Reclamation.removed, reclamation);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
        var name_buffer: [96]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "request-{d}-{d}.tmp", .{ binding.operation_id, binding.attempt_ordinal });
        try std.testing.expectError(error.FileNotFound, setup.tmp.dir.statFile(std.testing.io, name, .{}));
    }
}

test "request preparation completed request is fenced by later stop before handoff" {
    var setup: PreparationTestSetup = undefined;
    try setup.init();
    defer setup.close();
    try setup.configure("prep-fence-config", "direct/prep-fence");
    try setup.submit("prep-fence-file", "prep-fence-message", "direct/prep-fence", "work");
    var admitted = (try setup.storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();
    const view = try setup.storage.openHistoricalView(binding);
    // Nonzero unrelated baseline stays stable; the sealed request owns its
    // reservation until its recipient releases it.
    var used: std.atomic.Value(u64) = .init(41);
    const baseline = used.load(.acquire);
    var retained: ?named_scratch.Owner = null;
    var preparation: Preparation = undefined;
    try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
    // Guard the active preparation before any fallible observation: an
    // error before the request reaches the caller must still cancel it.
    // After sealing the preparation is inactive and this guard is inert.
    defer if (preparation.active) preparation.cancel();
    try preparation.checkIntegrity(binding);
    // The sealed request stays owned and readable across the stop and the
    // refused handoff; only its release returns the charge.
    var request = try drainLivePreparation(&preparation, preparation_byte_allowance, preparation_item_allowance, 4096);
    var released = false;
    defer {
        if (!released) request.deinit();
    }
    try std.testing.expect(request.length > 0);
    // Sealing transfers the writer reservation to the request recipient: the
    // total is unchanged, only the responsible owner changes, and a
    // successful seal charges exactly the sealed bytes.
    try std.testing.expectEqual(request.length, request.charged);
    try std.testing.expectEqual(baseline + request.charged, used.load(.acquire));
    const readable = try request.file.length(request.io);
    try std.testing.expectEqual(request.length, readable);

    // A sealed request is not dispatch permission: a stop accepted after
    // preparation but before handoff refuses the launch callback.
    var stop: protocol.SessionStopCommand = .{};
    try stop.key.set("prep-fence-stop");
    try stop.session.set("direct/prep-fence");
    try std.testing.expect(setup.storage.stopSession(&stop, .{}) == .accepted);
    const Launcher = struct {
        fn run(calls: *usize) !void {
            calls.* += 1;
        }
    };
    var calls: usize = 0;
    try std.testing.expectError(error.SupersededByControl, setup.storage.withDispatchHandoff(binding, &calls, Launcher.run));
    try std.testing.expectEqual(@as(usize, 0), calls);
    try std.testing.expectEqual(request.length, try request.file.length(request.io));
    // The refused handoff releases nothing: the live request stays readable
    // and charged until its recipient releases it.
    try std.testing.expectEqual(baseline + request.charged, used.load(.acquire));
    request.deinit();
    released = true;
    try std.testing.expectEqual(baseline, used.load(.acquire));
}

test "a bound trip releases ownership whether or not the sealing advance fired" {
    var setup: PreparationTestSetup = undefined;
    try setup.init();
    defer setup.close();
    try setup.configure("prep-bound-config", "direct/prep-bound");
    try setup.submit("prep-bound-file", "prep-bound-message", "direct/prep-bound", "work");
    var admitted = (try setup.storage.admitNextModelAttempt(.{})).?;
    const binding = try admitted.permit.consume();

    // Small allowances force many advances, so the probe count supports
    // both a trip while pending and a trip on the sealing advance.
    // Deterministic content keeps the count stable across the probe and
    // the guarded drains below.
    const probe_allowance = [_]usize{ 16, 2 };
    const seal_steps = blk: {
        const probe_view = try setup.storage.openHistoricalView(binding);
        var probe_used: std.atomic.Value(u64) = .init(0);
        var probe_retained: ?named_scratch.Owner = null;
        var probe: Preparation = undefined;
        try probe.init(std.testing.io, probe_view, setup.root, .{ .used = &probe_used, .limit = 8 * 1024 * 1024 }, .{}, &probe_retained);
        defer if (probe.active) probe.cancel();
        var count: usize = 0;
        while (count < 4096) {
            count += 1;
            var progress = probe.advance(probe_allowance[0], probe_allowance[1]);
            switch (progress) {
                .pending => {},
                // The probe owns this terminal result with no fallible
                // step before release, so a single scope holds cleanup.
                .prepared => |*sealed| {
                    sealed.deinit();
                    break :blk count;
                },
                .failed => |err| return err,
            }
        }
        return error.TestExpectedResult;
    };
    // Both sub-cases below must trip their bound; a degenerate single-step
    // seal would silently test nothing.
    try std.testing.expect(seal_steps > 2);

    // A trip while preparation is still pending leaves it active with an
    // outstanding charge: the caller's preparation guard cancels and the
    // baseline is restored. The same tripwire error fires here and below;
    // budget and preparation state are the load-bearing assertions.
    {
        const view = try setup.storage.openHistoricalView(binding);
        var used: std.atomic.Value(u64) = .init(13);
        const baseline = used.load(.acquire);
        var retained: ?named_scratch.Owner = null;
        var preparation: Preparation = undefined;
        try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
        defer if (preparation.active) preparation.cancel();
        try std.testing.expectError(error.TestUnexpectedResult, drainLivePreparation(&preparation, probe_allowance[0], probe_allowance[1], 1));
        try std.testing.expect(preparation.active);
        try std.testing.expect(used.load(.acquire) > baseline);
        preparation.cancel();
        try std.testing.expect(!preparation.active);
        try std.testing.expectEqual(baseline, used.load(.acquire));
        try std.testing.expect(retained == null);
    }

    // A trip on the sealing advance acquires the terminal request inside
    // the helper before the bound fails: the helper's guard must release
    // it before the error escapes. The preparation is already inactive,
    // so the caller's guard stays inert and no second owner exists.
    {
        const view = try setup.storage.openHistoricalView(binding);
        var used: std.atomic.Value(u64) = .init(13);
        const baseline = used.load(.acquire);
        var retained: ?named_scratch.Owner = null;
        var preparation: Preparation = undefined;
        try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
        defer if (preparation.active) preparation.cancel();
        try std.testing.expectError(error.TestUnexpectedResult, drainLivePreparation(&preparation, probe_allowance[0], probe_allowance[1], seal_steps - 1));
        try std.testing.expect(!preparation.active);
        try std.testing.expectEqual(baseline, used.load(.acquire));
        try std.testing.expect(retained == null);
    }
}

test "request preparation composes replay tool results and schema" {
    for ([_][2]usize{ .{ 16, 2 }, .{ 1, 1 }, .{ 16384, 64 } }) |schedule| {
        var setup: PreparationTestSetup = undefined;
        try setup.init();
        defer setup.close();
        const binding = try establishComposedHistory(&setup, "direct/prep-composed");
        const view = try setup.storage.openHistoricalView(binding);
        var used: std.atomic.Value(u64) = .init(0);
        var retained: ?named_scratch.Owner = null;
        var preparation: Preparation = undefined;
        try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
        const result = try drainPreparation(&preparation, schedule[0], schedule[1], 16384);
        defer std.testing.allocator.free(result.bytes);
        try std.testing.expectEqualStrings(composed_expected, result.bytes);
        try std.testing.expectEqual(@as(u64, composed_expected.len), result.length);
        try std.testing.expectEqual(protocol.contentDigest(composed_expected), result.digest);
        try std.testing.expectEqual(@as(u64, 0), used.load(.acquire));
    }
}

test "request preparation cancels inside schema and replay emissions" {
    // Checkpoint offsets come straight from the independently authored
    // composed golden the dedicated test already verifies byte-for-byte.
    const schema_target = std.mem.indexOf(u8, composed_expected, "{\"type\":\"object\"}").? + 2;
    const replay_target = std.mem.indexOf(u8, composed_expected, composed_replayed).? + composed_replayed.len / 2;

    // Each target lies strictly inside its emission's output span, so the
    // corresponding raw or replay reader is necessarily still open with a
    // partial charge outstanding when preparation is cancelled.
    for ([_]u64{ schema_target, replay_target }) |target| {
        var setup: PreparationTestSetup = undefined;
        try setup.init();
        defer setup.close();
        const binding = try establishComposedHistory(&setup, "direct/prep-cancel-spans");
        const view = try setup.storage.openHistoricalView(binding);
        var used: std.atomic.Value(u64) = .init(0);
        const baseline = used.load(.acquire);
        var retained: ?named_scratch.Owner = null;
        var preparation: Preparation = undefined;
        try preparation.init(std.testing.io, view, setup.root, .{ .used = &used, .limit = 8 * 1024 * 1024 }, .{}, &retained);
        defer if (preparation.active) preparation.cancel();
        try stepPreparationToOffset(&preparation, target, 16384);
        // Direct owner prerequisite for each emission family: the intended
        // reader is active with a reservation outstanding.
        try preparation.checkIntegrity(binding);
        try std.testing.expectEqual(@as(usize, 1), preparation.view.outstandingReaders());
        try std.testing.expect(used.load(.acquire) > baseline);
        preparation.cancel();
        try std.testing.expect(!preparation.active);
        try std.testing.expectEqual(baseline, used.load(.acquire));
        try std.testing.expect(retained == null);
    }
}
