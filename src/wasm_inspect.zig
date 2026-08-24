const std = @import("std");

pub const Report = struct {
    imports: u32 = 0,
    tables: u32 = 0,
    table_ref_type: u8 = 0,
    table_min: u64 = 0,
    table_max: ?u64 = null,
    memories: u32 = 0,
    memory_min_pages: u64 = 0,
    memory_max_pages: ?u64 = null,
    globals: u32 = 0,
    mutable_globals: u32 = 0,
    first_global_type: u8 = 0,
    first_global_i32_init: ?i32 = null,
    exports: u32 = 0,
    function_exports: u32 = 0,
    table_exports: u32 = 0,
    memory_exports: u32 = 0,
    global_exports: u32 = 0,
    global_reads: u32 = 0,
    global_writes: u32 = 0,
    table_reads: u32 = 0,
    table_writes: u32 = 0,
    indirect_calls: u32 = 0,
    memory_grows: u32 = 0,
    data_section_bytes: usize = 0,
};

pub fn inspect(module: []const u8) !Report {
    if (module.len < 8 or !std.mem.eql(u8, module[0..8], "\x00asm\x01\x00\x00\x00")) {
        return error.InvalidHeader;
    }

    var reader: Reader = .{ .bytes = module, .index = 8 };
    var report: Report = .{};
    while (!reader.done()) {
        const section_id = try reader.byte();
        const section_size = try reader.uleb(u32);
        const section = try reader.take(section_size);
        var payload: Reader = .{ .bytes = section };

        switch (section_id) {
            2 => report.imports = try payload.uleb(u32),
            4 => try inspectTable(&payload, &report),
            5 => try inspectMemory(&payload, &report),
            6 => try inspectGlobals(&payload, &report),
            7 => try inspectExports(&payload, &report),
            10 => try inspectCode(&payload, &report),
            11 => report.data_section_bytes = section.len,
            else => {},
        }
    }
    return report;
}

fn inspectTable(reader: *Reader, report: *Report) !void {
    report.tables = try reader.uleb(u32);
    if (report.tables != 1) return;

    report.table_ref_type = try reader.byte();
    const limits = try readLimits(reader);
    report.table_min = limits.min;
    report.table_max = limits.max;
}

fn inspectMemory(reader: *Reader, report: *Report) !void {
    report.memories = try reader.uleb(u32);
    if (report.memories != 1) return;

    const flags = try reader.uleb(u32);
    report.memory_min_pages = try reader.uleb(u64);
    if (flags & 0x1 != 0) report.memory_max_pages = try reader.uleb(u64);
}

fn inspectGlobals(reader: *Reader, report: *Report) !void {
    report.globals = try reader.uleb(u32);
    var remaining = report.globals;
    while (remaining > 0) : (remaining -= 1) {
        const value_type = try reader.byte();
        if (remaining == report.globals) report.first_global_type = value_type;
        const mutable = try reader.byte();
        if (mutable > 1) return error.InvalidMutability;
        report.mutable_globals += mutable;
        const initial = try readConstExpression(reader);
        if (remaining == report.globals) report.first_global_i32_init = initial;
    }
}

fn inspectExports(reader: *Reader, report: *Report) !void {
    report.exports = try reader.uleb(u32);
    var remaining = report.exports;
    while (remaining > 0) : (remaining -= 1) {
        const name_len = try reader.uleb(u32);
        _ = try reader.take(name_len);
        const kind = try reader.byte();
        _ = try reader.uleb(u32);
        switch (kind) {
            0 => report.function_exports += 1,
            1 => report.table_exports += 1,
            2 => report.memory_exports += 1,
            3 => report.global_exports += 1,
            else => {},
        }
    }
}

fn inspectCode(reader: *Reader, report: *Report) !void {
    var functions = try reader.uleb(u32);
    while (functions > 0) : (functions -= 1) {
        const body_size = try reader.uleb(u32);
        const body_bytes = try reader.take(body_size);
        var body: Reader = .{ .bytes = body_bytes };

        var local_groups = try body.uleb(u32);
        while (local_groups > 0) : (local_groups -= 1) {
            _ = try body.uleb(u32);
            _ = try body.byte();
        }

        while (!body.done()) {
            const opcode = try body.byte();
            switch (opcode) {
                0x0b, 0x1a, 0x1b, 0x45...0xbf => {},
                0x10, 0x20...0x22, 0xd2 => _ = try body.uleb(u32),
                0x11 => {
                    _ = try body.uleb(u32);
                    _ = try body.uleb(u32);
                    report.indirect_calls += 1;
                },
                0x23 => {
                    _ = try body.uleb(u32);
                    report.global_reads += 1;
                },
                0x24 => {
                    _ = try body.uleb(u32);
                    report.global_writes += 1;
                },
                0x25 => {
                    _ = try body.uleb(u32);
                    report.table_reads += 1;
                },
                0x26 => {
                    _ = try body.uleb(u32);
                    report.table_writes += 1;
                },
                0x28...0x3e => {
                    _ = try body.uleb(u32);
                    _ = try body.uleb(u32);
                },
                0x3f => _ = try body.uleb(u32),
                0x40 => {
                    _ = try body.uleb(u32);
                    report.memory_grows += 1;
                },
                0x41 => _ = try body.sleb(i32),
                0x42 => _ = try body.sleb(i64),
                0x43 => _ = try body.take(4),
                0x44 => _ = try body.take(8),
                0xd0 => _ = try body.byte(),
                else => return error.UnsupportedInstruction,
            }
        }
    }
}

fn readConstExpression(reader: *Reader) !?i32 {
    const opcode = try reader.byte();
    const i32_value: ?i32 = switch (opcode) {
        0x41 => try reader.sleb(i32),
        0x42 => blk: {
            _ = try reader.sleb(i64);
            break :blk null;
        },
        0x43 => blk: {
            _ = try reader.take(4);
            break :blk null;
        },
        0x44 => blk: {
            _ = try reader.take(8);
            break :blk null;
        },
        0x23, 0xd2 => blk: {
            _ = try reader.uleb(u32);
            break :blk null;
        },
        0xd0 => blk: {
            _ = try reader.byte();
            break :blk null;
        },
        else => return error.UnsupportedConstExpression,
    };
    if (try reader.byte() != 0x0b) return error.UnterminatedConstExpression;
    return i32_value;
}

const Limits = struct { min: u64, max: ?u64 };

fn readLimits(reader: *Reader) !Limits {
    const flags = try reader.uleb(u32);
    const min = try reader.uleb(u64);
    const max = if (flags & 0x1 != 0) try reader.uleb(u64) else null;
    return .{ .min = min, .max = max };
}

const Reader = struct {
    bytes: []const u8,
    index: usize = 0,

    fn done(self: *const Reader) bool {
        return self.index == self.bytes.len;
    }

    fn byte(self: *Reader) !u8 {
        if (self.index >= self.bytes.len) return error.UnexpectedEnd;
        defer self.index += 1;
        return self.bytes[self.index];
    }

    fn take(self: *Reader, length: usize) ![]const u8 {
        if (length > self.bytes.len - self.index) return error.UnexpectedEnd;
        defer self.index += length;
        return self.bytes[self.index .. self.index + length];
    }

    fn uleb(self: *Reader, comptime T: type) !T {
        var result: T = 0;
        var shift: usize = 0;
        while (shift < @bitSizeOf(T)) : (shift += 7) {
            const current = try self.byte();
            result |= @as(T, current & 0x7f) << @intCast(shift);
            if (current & 0x80 == 0) return result;
        }
        return error.IntegerOverflow;
    }

    fn sleb(self: *Reader, comptime T: type) !T {
        var result: T = 0;
        var shift: usize = 0;
        var current: u8 = 0;
        while (shift < @bitSizeOf(T)) : (shift += 7) {
            current = try self.byte();
            result |= @as(T, @intCast(current & 0x7f)) << @intCast(shift);
            if (current & 0x80 == 0) {
                const used_bits = shift + 7;
                if (used_bits < @bitSizeOf(T) and current & 0x40 != 0) {
                    result |= @as(T, -1) << @intCast(used_bits);
                }
                return result;
            }
        }
        return error.IntegerOverflow;
    }
};

test "inspect exact one-page memory" {
    const module = "\x00asm\x01\x00\x00\x00" ++
        "\x05\x04\x01\x01\x01\x01" ++
        "\x07\x0a\x01\x06memory\x02\x00";
    const report = try inspect(module);
    try std.testing.expectEqual(@as(u32, 1), report.memories);
    try std.testing.expectEqual(@as(u64, 1), report.memory_min_pages);
    try std.testing.expectEqual(@as(?u64, 1), report.memory_max_pages);
    try std.testing.expectEqual(@as(u32, 1), report.memory_exports);
}

test "reject malformed header" {
    try std.testing.expectError(error.InvalidHeader, inspect("not wasm"));
}

test "enumerate globals tables exports and code access" {
    const module = "\x00asm\x01\x00\x00\x00" ++
        "\x04\x05\x01\x70\x01\x01\x01" ++
        "\x06\x07\x01\x7f\x01\x41\x80\x20\x0b" ++
        "\x07\x05\x01\x01t\x01\x00" ++
        "\x0a\x0c\x01\x0a\x00\x23\x00\x1a\x41\x00\x25\x00\x1a\x0b";
    const report = try inspect(module);

    try std.testing.expectEqual(@as(u32, 1), report.tables);
    try std.testing.expectEqual(@as(u8, 0x70), report.table_ref_type);
    try std.testing.expectEqual(@as(u64, 1), report.table_min);
    try std.testing.expectEqual(@as(?u64, 1), report.table_max);
    try std.testing.expectEqual(@as(u32, 1), report.table_exports);
    try std.testing.expectEqual(@as(u32, 1), report.globals);
    try std.testing.expectEqual(@as(u32, 1), report.mutable_globals);
    try std.testing.expectEqual(@as(u8, 0x7f), report.first_global_type);
    try std.testing.expectEqual(@as(?i32, 4096), report.first_global_i32_init);
    try std.testing.expectEqual(@as(u32, 1), report.global_reads);
    try std.testing.expectEqual(@as(u32, 1), report.table_reads);
}
