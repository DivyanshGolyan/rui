const std = @import("std");
const codex_native = @import("codex_native.zig");
const codex_provider = @import("codex_provider.zig");
const model_contract = @import("model_contract.zig");
const model_operation = @import("model_operation.zig");
const model_protocol = @import("model_protocol.zig");

pub fn main(init: std.process.Init) !void {
    var buffer: [2048]u8 = undefined;
    const report = try std.fmt.bufPrint(
        &buffer,
        "{{\n" ++
            "  \"capture_struct_bytes\": {d},\n" ++
            "  \"credential_struct_bytes\": {d},\n" ++
            "  \"provider_io_struct_bytes\": {d},\n" ++
            "  \"tool_mapping_struct_bytes\": {d},\n" ++
            "  \"request_reader_struct_bytes\": {d},\n" ++
            "  \"request_read_window_bytes\": {d},\n" ++
            "  \"response_head_window_bytes\": {d},\n" ++
            "  \"diagnostic_body_limit_bytes\": {d},\n" ++
            "  \"diagnostic_transfer_window_bytes\": {d},\n" ++
            "  \"transport_library_state_measured_separately\": true,\n" ++
            "  \"sse_projection_window_bytes\": {d},\n" ++
            "  \"assistant_text_buffer_limit_bytes\": {d},\n" ++
            "  \"tool_arguments_buffer_limit_bytes\": {d},\n" ++
            "  \"decoded_buffers_allocate_to_actual_content\": true,\n" ++
            "  \"sse_event_work_limit_bytes\": {d},\n" ++
            "  \"sse_stream_limit_bytes\": {d}\n" ++
            "}}\n",
        .{
            @sizeOf(codex_provider.Capture),
            @sizeOf(codex_provider.Credential),
            @sizeOf(model_operation.ProviderIo),
            @sizeOf(codex_provider.ToolMapping),
            @sizeOf(codex_provider.RequestReader),
            codex_provider.request_window_size,
            codex_native.response_head_window_size,
            codex_native.diagnostic_body_limit,
            codex_native.diagnostic_transfer_window_size,
            codex_provider.sse_projection_window_size,
            model_protocol.max_assistant_text_size,
            model_contract.max_tool_arguments_envelope_size,
            codex_provider.max_sse_event_bytes,
            codex_provider.max_total_sse_bytes,
        },
    );
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}
