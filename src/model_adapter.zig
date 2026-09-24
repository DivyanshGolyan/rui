const std = @import("std");
const codex_auth = @import("codex_auth.zig");
const codex_credentials = @import("codex_credentials.zig");
const named_scratch = @import("named_scratch.zig");
const platform = @import("platform.zig");
const protocol = @import("protocol.zig");
const provider = @import("provider.zig");
pub const Output = @import("provider_output.zig");
const request_encoding = @import("request_encoding.zig");
const store = @import("store.zig");
const tools = @import("tools.zig");

const ScratchBudget = provider.ScratchBudget;
const PreparedRequest = provider.PreparedRequest;

// The sole V1 model adapter owns Codex wire grammar, output interpretation,
// and managed-route authentication. The Host owns only effect scheduling and
// the provider transport owns only curl and sealed byte lifetimes.
pub const provider_label = "codex";
pub const managed_endpoint = "https://chatgpt.com/backend-api/codex/responses";
pub const observation_names: provider.ObservationNames = .{
    .request_id = "x-request-id",
    .model = "openai-model",
    .alternate_model = "x-openai-model",
};
pub const Authentication = struct { path: []const u8, fixture: bool = false };
pub const Credential = codex_credentials.Lease;

pub fn acquireCredential(io: std.Io, authentication: Authentication) !Credential {
    return codex_auth.acquire(io, authentication.path, authentication.fixture);
}

pub fn authenticationFailureCode(err: anyerror) []const u8 {
    return codex_auth.failureCode(err);
}

pub fn preparationFailureCode(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedCodexConfiguration => "unsupported_codex_configuration",
        error.InjectedFirstPreparationFailure => "request_preparation_failed",
        error.RequestScratchExhausted => "request_scratch_exhausted",
        error.InjectedRequestWriteFailure => "request_write_failed",
        error.InjectedRequestSealFailure, error.RequestSealFailed => "request_seal_failed",
        else => "request_preparation_failed",
    };
}

fn fixtureEndpoint(endpoint: []const u8, ca_file: ?[]const u8) bool {
    return std.mem.startsWith(u8, endpoint, "http://127.0.0.1:") or
        std.mem.startsWith(u8, endpoint, "http://[::1]:") or
        (std.mem.startsWith(u8, endpoint, "https://localhost:") and ca_file != null);
}

pub fn validateAuthenticationEndpoint(endpoint: []const u8, ca_file: ?[]const u8, authentication: Authentication) !void {
    if (authentication.fixture and !fixtureEndpoint(endpoint, ca_file))
        return error.InvalidCodexFixtureEndpoint;
}

pub const Headers = struct {
    bearer: [codex_credentials.max_token_bytes + 32:0]u8 = undefined,
    account: [codex_credentials.max_account_id_bytes + 32:0]u8 = undefined,
    entries: [4][:0]const u8 = undefined,
    length: usize = 0,

    /// Initialize in final stack storage. The entries are borrowed only until
    /// Transfer.start copies them into its owned curl header list.
    pub fn init(self: *Headers, endpoint: []const u8, ca_file: ?[]const u8, authentication: Authentication, credential: *const Credential) !void {
        const access = credential.record.access_token.slice();
        const account_id = credential.record.account_id.slice();
        if (authentication.fixture) {
            if (!fixtureEndpoint(endpoint, ca_file) or
                !std.mem.eql(u8, access, codex_auth.fixture_access_token) or
                !std.mem.eql(u8, account_id, codex_auth.fixture_account_id))
                return error.InvalidManagedFixture;
        } else if (!std.mem.eql(u8, endpoint, managed_endpoint)) return error.ManagedEndpointMismatch;
        if (access.len == 0 or account_id.len == 0)
            return error.InvalidCredentialHeader;
        for (access) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidCredentialHeader;
        for (account_id) |byte| if (byte < 0x21 or byte > 0x7e) return error.InvalidCredentialHeader;
        const bearer = try std.fmt.bufPrintZ(&self.bearer, "Authorization: Bearer {s}", .{access});
        const account = try std.fmt.bufPrintZ(&self.account, "ChatGPT-Account-ID: {s}", .{account_id});
        self.entries = .{ "Accept: text/event-stream", bearer, account, "X-OpenAI-Fedramp: true" };
        self.length = if (credential.record.fedramp) 4 else 3;
    }

    pub fn slice(self: *const Headers) []const [:0]const u8 {
        return self.entries[0..self.length];
    }

    pub fn deinit(self: *Headers) void {
        std.crypto.secureZero(u8, &self.bearer);
        std.crypto.secureZero(u8, &self.account);
        self.* = undefined;
    }
};

pub const PreparationFaults = struct {
    managed_route: bool = false,
    first_step: bool = false,
    write: bool = false,
    seal: bool = false,
    unlink: bool = false,
    // Test-owned removal gate for the retained unlink-failure owner. When
    // set alongside unlink, the retained owner uses this gate so the test
    // can complete reclamation through the production path.
    unlink_removal: ?*const std.atomic.Value(bool) = null,
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
        instructions_content,
        input_prefix,
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
                    if (self.faults.managed_route and
                        (self.settings.?.tools_mask & 2 != 0 or self.settings.?.output_schema != null))
                        return .{ .failed = error.UnsupportedCodexConfiguration };
                    self.phase = switch (self.settings.?.provider) {
                        .codex => .model_prefix,
                    };
                },
                .model_prefix => self.emitFixed("{\"model\":\"", .model),
                .model => self.emitJsonBytes(self.settings.?.model.slice(), .envelope),
                .envelope => self.emitFixed("\",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"instructions\":\"", .instructions_content),
                .instructions_content => {
                    const reader = self.view.openContent(self.settings.?.baseline_instructions) catch |err| return .{ .failed = err };
                    self.emitJsonReader(reader, .input_prefix);
                },
                .input_prefix => self.emitFixed("\",\"input\":[", .history_next),
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
                            "{\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"";
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
    "{\"model\":\"model-a\",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"instructions\":\"\",\"input\":[" ++
    "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"do work\"}]}," ++
    composed_replayed ++ "," ++
    composed_replayed_call_a ++ "," ++
    composed_replayed_call_b ++ "," ++
    "{\"type\":\"function_call_output\",\"call_id\":\"order-call-a\",\"output\":\"Permission denied.\"}," ++
    "{\"type\":\"function_call_output\",\"call_id\":\"order-call-b\",\"output\":\"Permission denied.\"}]," ++
    "\"tools\":[" ++ bash_tool_json ++ "," ++ edit_tool_json ++ "]," ++
    "\"text\":{\"format\":{\"type\":\"json_schema\",\"name\":\"rui_output\",\"strict\":true,\"schema\":{\"type\":\"object\"}}}}";

test "request preparation minimal golden is exact across schedules" {
    const expected = "{\"model\":\"model-a\",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"instructions\":\"\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}]";
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
    const expected = "{\"model\":\"model-a\",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"],\"instructions\":\"\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]}],\"tools\":[" ++
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
