const std = @import("std");
const binding = @import("binding.zig");
const model_contract = @import("model_contract.zig");
const model_operation = @import("model_operation.zig");
const session_store = @import("host_store.zig");

const request_magic = "ONEREQ3\x00";

pub const Encoded = struct {
    bytes: []const u8,
};

/// Builds one provider-neutral request from bounded committed Conversation
/// windows. The caller owns the transient output and releases it before any
/// durable wait.
pub fn encode(
    store: *session_store.Store,
    session_id: u64,
    model: []const u8,
    out: []u8,
) !Encoded {
    if (session_id == 0 or model.len == 0 or model.len > 128 or
        !std.unicode.utf8ValidateSlice(model))
    {
        return error.InvalidModelRequest;
    }
    const entry_count = try store.sessionConversationRevision(session_id);
    if (entry_count == 0 or entry_count > std.math.maxInt(u32)) {
        return error.InvalidModelRequest;
    }
    const catalog = &model_contract.default_catalog;
    var cursor: usize = 0;
    var header: [model_operation.request_header_size]u8 = @splat(0);
    @memcpy(header[0..request_magic.len], request_magic);
    write(u16, &header, 8, model_operation.version);
    write(u16, &header, 10, model_operation.request_header_size);
    write(u32, &header, 12, @intCast(entry_count));
    write(u16, &header, 16, @intCast(catalog.len));
    write(u16, &header, 18, @intCast(model.len));
    write(u32, &header, 20, model_contract.default_instructions.len);
    write(u32, &header, 24, model_contract.model_contract_bytes.len);
    @memcpy(header[28..60], &model_contract.catalogDigest(catalog).bytes);
    const contract_digest = binding.hash(binding.ModelContract, model_contract.model_contract_bytes);
    @memcpy(header[60..92], &contract_digest.bytes);
    try append(out, &cursor, &header);
    try append(out, &cursor, model);
    try append(out, &cursor, model_contract.default_instructions);
    try append(out, &cursor, model_contract.model_contract_bytes);
    for (catalog) |definition| {
        var tool_header: [model_operation.tool_header_size]u8 = @splat(0);
        write(u16, &tool_header, 0, @intCast(definition.key.len));
        write(u16, &tool_header, 2, @intCast(definition.provider_tool_name.len));
        write(u32, &tool_header, 4, @intCast(definition.description.len));
        write(u32, &tool_header, 8, @intCast(definition.input_schema.len));
        write(u32, &tool_header, 12, @intCast(definition.result_contract.len));
        try append(out, &cursor, &tool_header);
        try append(out, &cursor, definition.key);
        try append(out, &cursor, definition.provider_tool_name);
        try append(out, &cursor, definition.description);
        try append(out, &cursor, definition.input_schema);
        try append(out, &cursor, definition.result_contract);
    }

    var after_revision: u64 = 0;
    var previous_entry_id: u64 = 0;
    var window: [session_store.max_conversation_window]session_store.ConversationEntry = undefined;
    while (after_revision < entry_count) {
        const count = try store.readConversation(session_id, after_revision, &window);
        if (count == 0) return error.CorruptConversation;
        for (window[0..count]) |entry| {
            if (entry.revision != after_revision + 1) return error.CorruptConversation;
            const content_length = try store.contentLength(entry.content_id);
            var entry_header: [model_operation.entry_header_size]u8 = @splat(0);
            entry_header[0] = @intFromEnum(entry.kind);
            write(u64, &entry_header, 8, entry.entry_id);
            write(u64, &entry_header, 16, previous_entry_id);
            write(u64, &entry_header, 24, content_length);
            try append(out, &cursor, &entry_header);
            if (content_length > out.len - cursor) return error.ModelRequestBufferTooSmall;
            const content = try store.readContent(entry.content_id, out[cursor..][0..content_length]);
            cursor += content.len;
            previous_entry_id = entry.entry_id;
            after_revision = entry.revision;
        }
    }
    return .{ .bytes = out[0..cursor] };
}

fn append(out: []u8, cursor: *usize, bytes: []const u8) !void {
    if (bytes.len > out.len - cursor.*) return error.ModelRequestBufferTooSmall;
    @memcpy(out[cursor.*..][0..bytes.len], bytes);
    cursor.* += bytes.len;
}

fn write(comptime T: type, out: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, out[offset..][0..@sizeOf(T)], value, .little);
}
