const std = @import("std");
const binding = @import("binding.zig");
const model_contract = @import("model_contract.zig");
const model_protocol = @import("model_protocol.zig");
const session_store = @import("session.zig");

pub const request_header_size = 92;
pub const tool_header_size = 20;
pub const entry_header_size = 32;
pub const request_window_size = 4096;
pub const version: u16 = 2;

const request_magic = "ONEREQ2\x00";

pub fn verifyRequestDigest(
    session: *session_store.Session,
    request_ref: u64,
    expected: binding.ModelDescriptor,
) !void {
    var request = try session.openBlob(request_ref);
    defer request.close();
    var hasher = binding.Hasher(binding.ModelDescriptor).init();
    var window: [request_window_size]u8 = undefined;
    var offset: u64 = 0;
    while (offset < request.length()) {
        const bytes = try request.readWindow(offset, &window);
        if (bytes.len == 0) return error.TruncatedModelRequest;
        hasher.update(bytes);
        offset += bytes.len;
    }
    if (!binding.eql(binding.ModelDescriptor, hasher.final(), expected)) {
        return error.ModelRequestDigestMismatch;
    }
}

pub const Provider = struct {
    context: *anyopaque,
    dispatch: *const fn (
        *anyopaque,
        RequestReader,
        ResponseWriter,
    ) anyerror!void,
};

pub const RequestReader = struct {
    context: *anyopaque,
    length_fn: *const fn (*anyopaque) u64,
    read_fn: *const fn (*anyopaque, u64, []u8) anyerror![]const u8,

    pub fn length(self: RequestReader) u64 {
        return self.length_fn(self.context);
    }

    pub fn readWindow(self: RequestReader, offset: u64, out: []u8) ![]const u8 {
        return self.read_fn(self.context, offset, out);
    }
};

pub const ResponseWriter = struct {
    context: *anyopaque,
    append_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    finish_fn: *const fn (*anyopaque) anyerror!void,

    pub fn append(self: ResponseWriter, bytes: []const u8) !void {
        try self.append_fn(self.context, bytes);
    }

    pub fn finish(self: ResponseWriter) !void {
        try self.finish_fn(self.context);
    }
};

/// Owns the host-side resources behind the deliberately narrow provider
/// capabilities. Providers can read one immutable request and append one
/// predetermined response; they receive no Session or owner authority.
pub const ProviderIo = struct {
    request: session_store.BlobReader,
    response: session_store.BlobWriter,

    pub fn open(
        session: *session_store.Session,
        request_ref: u64,
        response_ref: u64,
    ) !ProviderIo {
        var request = try session.openBlob(request_ref);
        errdefer request.close();
        const response = try session.beginBlob(response_ref);
        return .{ .request = request, .response = response };
    }

    pub fn close(self: *ProviderIo) void {
        self.request.close();
        self.response.abort();
    }

    pub fn requestCapability(self: *ProviderIo) RequestReader {
        return .{ .context = self, .length_fn = requestLength, .read_fn = requestRead };
    }

    pub fn responseCapability(self: *ProviderIo) ResponseWriter {
        return .{ .context = self, .append_fn = responseAppend, .finish_fn = responseFinish };
    }

    pub fn ensureResponsePublished(self: *const ProviderIo) !void {
        if (self.response.open) return error.ProviderResponseIncomplete;
    }

    pub fn publishProviderFailure(
        self: *ProviderIo,
        session: *session_store.Session,
        response_ref: u64,
    ) !u64 {
        self.response.abort();
        return publishFailureResult(session, response_ref);
    }

    fn requestLength(context: *anyopaque) u64 {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        return self.request.length();
    }

    fn requestRead(context: *anyopaque, offset: u64, out: []u8) anyerror![]const u8 {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        return self.request.readWindow(offset, out);
    }

    fn responseAppend(context: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        try self.response.append(bytes);
    }

    fn responseFinish(context: *anyopaque) anyerror!void {
        const self: *ProviderIo = @ptrCast(@alignCast(context));
        try self.response.finish();
    }
};

pub fn publishFailureResult(
    session: *session_store.Session,
    identity: u64,
) !u64 {
    const failure_ref = (@as(u64, 1) << 56) | (identity & ((@as(u64, 1) << 56) - 1));
    var buffer: [model_protocol.header_size]u8 = undefined;
    const encoded = try model_protocol.encodeFailure(&buffer, .provider_error);
    try session.storeBlob(failure_ref, encoded);
    return failure_ref;
}

pub fn buildRequest(
    session: *session_store.Session,
    request_ref: u64,
    first_entry: u32,
    entry_count: u32,
) !binding.ModelDescriptor {
    if (request_ref == 0 or first_entry == 0 or entry_count == 0) {
        return error.InvalidContextSelection;
    }
    const last = @as(u64, first_entry) + entry_count - 1;
    if (last > session.entryCount()) return error.InvalidContextSelection;
    const first = try session.readEntry(first_entry);
    const last_entry = try session.readEntry(last);
    if (first.kind == .tool_result or last_entry.kind == .tool_call) {
        return error.ContextSplitsToolPair;
    }

    const catalog_digest = try model_contract.catalogDigest(&model_contract.default_catalog);
    const contract_digest = binding.hash(binding.ModelContract, model_contract.model_contract_bytes);

    var writer = try session.beginBlob(request_ref);
    errdefer writer.abort();
    var hasher = binding.Hasher(binding.ModelDescriptor).init();
    var request_header: [request_header_size]u8 = @splat(0);
    @memcpy(request_header[0..request_magic.len], request_magic);
    write(u16, &request_header, 8, version);
    write(u16, &request_header, 10, request_header_size);
    write(u32, &request_header, 12, entry_count);
    write(u16, &request_header, 16, model_contract.default_catalog.len);
    write(u16, &request_header, 18, @intCast(session.modelName().len));
    write(u32, &request_header, 20, model_contract.default_instructions.len);
    write(u32, &request_header, 24, model_contract.model_contract_bytes.len);
    @memcpy(request_header[28..60], &catalog_digest.bytes);
    @memcpy(request_header[60..92], &contract_digest.bytes);
    try appendHashed(&writer, &hasher, &request_header);
    try appendHashed(&writer, &hasher, session.modelName());
    try appendHashed(&writer, &hasher, model_contract.default_instructions);
    try appendHashed(&writer, &hasher, model_contract.model_contract_bytes);
    for (model_contract.default_catalog) |definition| {
        var tool_header: [tool_header_size]u8 = @splat(0);
        write(u16, &tool_header, 0, @intCast(definition.key.len));
        write(u16, &tool_header, 2, @intCast(definition.provider_tool_name.len));
        write(u32, &tool_header, 4, @intCast(definition.description.len));
        write(u32, &tool_header, 8, @intCast(definition.input_schema.len));
        write(u32, &tool_header, 12, @intCast(definition.result_contract.len));
        try appendHashed(&writer, &hasher, &tool_header);
        try appendHashed(&writer, &hasher, definition.key);
        try appendHashed(&writer, &hasher, definition.provider_tool_name);
        try appendHashed(&writer, &hasher, definition.description);
        try appendHashed(&writer, &hasher, definition.input_schema);
        try appendHashed(&writer, &hasher, definition.result_contract);
    }

    var sequence: u64 = first_entry;
    while (sequence <= last) : (sequence += 1) {
        const entry = try session.readEntry(sequence);
        var content = try session.openBlob(entry.content_ref);
        defer content.close();
        var entry_header: [entry_header_size]u8 = @splat(0);
        entry_header[0] = @intFromEnum(entry.kind);
        write(u64, &entry_header, 8, entry.entry_id);
        write(u64, &entry_header, 16, entry.parent_id);
        write(u64, &entry_header, 24, content.length());
        try appendHashed(&writer, &hasher, &entry_header);

        var window: [request_window_size]u8 = undefined;
        var offset: u64 = 0;
        while (offset < content.length()) {
            const bytes = try content.readWindow(offset, &window);
            if (bytes.len == 0) return error.TruncatedContextBlob;
            try appendHashed(&writer, &hasher, bytes);
            offset += bytes.len;
        }
    }
    try writer.finish();

    return hasher.final();
}

fn appendHashed(
    writer: *session_store.BlobWriter,
    hasher: *binding.Hasher(binding.ModelDescriptor),
    bytes: []const u8,
) !void {
    try writer.append(bytes);
    hasher.update(bytes);
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}
