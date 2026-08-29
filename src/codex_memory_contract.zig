const std = @import("std");
const codex_native = @import("codex_native.zig");
const codex_provider = @import("codex_provider.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");

const http_read_buffer_size: usize = 8192;
const http_write_buffer_size: usize = 1024;
const https_connection_byte_buffer_floor = 3 * std.crypto.tls.Client.min_buffer_len +
    http_read_buffer_size + http_write_buffer_size;

pub fn main(init: std.process.Init) !void {
    var buffer: [2048]u8 = undefined;
    const report = try std.fmt.bufPrint(
        &buffer,
        "{{\n" ++
            "  \"capture_struct_bytes\": {d},\n" ++
            "  \"credential_struct_bytes\": {d},\n" ++
            "  \"provider_io_struct_bytes\": {d},\n" ++
            "  \"tool_mapping_struct_bytes\": {d},\n" ++
            "  \"request_read_window_bytes\": {d},\n" ++
            "  \"response_head_window_bytes\": {d},\n" ++
            "  \"stream_transfer_window_bytes\": {d},\n" ++
            "  \"diagnostic_body_limit_bytes\": {d},\n" ++
            "  \"diagnostic_transfer_window_bytes\": {d},\n" ++
            "  \"zig_https_connection_byte_buffer_floor_bytes\": {d},\n" ++
            "  \"decoded_candidate_limit_bytes\": {d},\n" ++
            "  \"sse_frame_limit_bytes\": {d},\n" ++
            "  \"sse_stream_limit_bytes\": {d}\n" ++
            "}}\n",
        .{
            @sizeOf(codex_provider.Capture),
            @sizeOf(codex_provider.Credential),
            @sizeOf(model_operation.ProviderIo),
            @sizeOf(codex_provider.ToolMapping),
            codex_provider.request_window_size,
            codex_native.response_head_window_size,
            codex_native.stream_transfer_window_size,
            codex_native.diagnostic_body_limit,
            codex_native.diagnostic_transfer_window_size,
            https_connection_byte_buffer_floor,
            model_protocol.max_response_size,
            codex_provider.max_sse_frame_size,
            codex_provider.max_total_sse_bytes,
        },
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
