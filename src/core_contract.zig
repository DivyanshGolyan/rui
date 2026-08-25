const std = @import("std");
const core_image = @import("core_image.zig");
const wasm_inspect = @import("wasm_inspect.zig");

pub fn verify(wasm: []const u8) !void {
    const report = try wasm_inspect.inspect(wasm);
    if (report.imports != 0 or
        report.memories != 1 or
        report.memory_min_pages != 1 or
        report.memory_max_pages == null or
        report.memory_max_pages.? != 1 or
        report.memory_exports != 1 or
        report.tables != 1 or
        report.table_ref_type != 0x70 or
        report.table_min != 1 or
        report.table_max == null or
        report.table_max.? != 1 or
        report.table_exports != 0 or
        report.table_reads != 0 or
        report.table_writes != 0 or
        report.indirect_calls != 0 or
        report.globals != 1 or
        report.mutable_globals != 1 or
        report.first_global_type != 0x7f or
        report.first_global_i32_init != 4 * 1024 or
        report.global_exports != 0 or
        report.global_reads != 0 or
        report.global_writes != 0 or
        report.memory_grows != 0 or
        report.function_exports != 32 or
        report.exports != 33 or
        report.data_section_bytes > 1024 or
        report.passive_data_segments != 0 or
        report.active_data_end > core_image.state_memory_offset)
    {
        return error.OnePageContractViolated;
    }
}

test "rejects a growable core image" {
    const module = "\x00asm\x01\x00\x00\x00" ++
        "\x05\x04\x01\x01\x01\x02" ++
        "\x07\x0a\x01\x06memory\x02\x00";

    try std.testing.expectError(error.OnePageContractViolated, verify(module));
}
