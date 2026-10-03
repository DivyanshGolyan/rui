const std = @import("std");

pub const capacity = 16;
pub const pending_capacity = 4;

pub const Work = struct {
    pub const Status = enum { idle, runnable, in_flight, waiting_for_permission };
    status: Status = .idle,
    turn: u64 = 0,
    operation: u64 = 0,
};

pub const Cursor = struct {
    end: u64 = 0,
    position: u64 = 0,
    ordinal: u64 = 0,
    recent: bool = false,
};

pub const Item = struct {
    pub const Kind = enum { admission, user, assistant, call, tool_result, outcome, stop };
    position: u64,
    ordinal: u64 = 0,
    kind: Kind,
    message: u64 = 0,
    turn: u64 = 0,
    operation: u64 = 0,
    call: u64 = 0,
    cutoff: u64 = 0,
    bytes: u64 = 0,
    code: [96]u8 = undefined,
    code_len: usize = 0,

    pub fn codeText(self: *const Item) []const u8 {
        return self.code[0..self.code_len];
    }
};

/// Value-owned metadata only. Payload windows belong to separate scoped reads.
pub const Page = struct {
    end: u64,
    items: [capacity]Item = undefined,
    count: usize = 0,
    more: bool = false,
    pending: [pending_capacity]Item = undefined,
    pending_count: usize = 0,
    pending_total: u64 = 0,
    // Current attention is a hint, not authority at the captured history end.
    action: u64 = 0,
    work: Work = .{},

    pub fn continuation(self: *const Page, previous: Cursor) Cursor {
        if (!self.more) {
            // Draining releases the fixed end, not the same-position result
            // ordinal. Empty polls retain that boundary until the end moves.
            const ordinal = if (self.count != 0) blk: {
                const last = self.items[self.count - 1];
                break :blk if (last.position == self.end) last.ordinal else 0;
            } else if (previous.position == self.end) previous.ordinal else 0;
            return .{ .position = self.end, .ordinal = ordinal };
        }
        const last = self.items[self.count - 1];
        return .{ .end = self.end, .position = last.position, .ordinal = last.ordinal };
    }
};

// Every scalar is a decimal string on the wire. Code has at most 6 escaped
// bytes per byte. Array/control overhead is independently bounded here.
pub const response_bytes = 384 + (capacity + pending_capacity) * (320 + 96 * 6);

pub fn writeItem(out: anytype, item: *const Item) !void {
    try out.appendFmt("{{\"position\":\"{d}\",\"ordinal\":\"{d}\",\"kind\":\"{s}\",\"message\":\"{d}\",\"turn\":\"{d}\",\"operation\":\"{d}\",\"call\":\"{d}\",\"cutoff\":\"{d}\",\"bytes\":\"{d}\",\"code\":", .{ item.position, item.ordinal, @tagName(item.kind), item.message, item.turn, item.operation, item.call, item.cutoff, item.bytes });
    try out.appendJsonString(item.codeText());
    try out.append("}");
}

const WireItem = struct {
    position: []const u8,
    ordinal: []const u8,
    kind: Item.Kind,
    message: []const u8,
    turn: []const u8,
    operation: []const u8,
    call: []const u8,
    cutoff: []const u8,
    bytes: []const u8,
    code: []const u8,

    fn value(self: WireItem) !Item {
        if (self.code.len > 96 or !std.unicode.utf8ValidateSlice(self.code)) return error.InvalidSessionView;
        var item: Item = .{
            .position = try number(self.position),
            .ordinal = try number(self.ordinal),
            .kind = self.kind,
            .message = try number(self.message),
            .turn = try number(self.turn),
            .operation = try number(self.operation),
            .call = try number(self.call),
            .cutoff = try number(self.cutoff),
            .bytes = try number(self.bytes),
            .code_len = self.code.len,
        };
        @memcpy(item.code[0..self.code.len], self.code);
        if (item.position == 0 or (item.kind != .tool_result and item.ordinal != 0) or
            ((item.kind == .user or item.kind == .admission) and item.message == 0) or
            ((item.kind == .assistant or item.kind == .outcome or item.kind == .call or item.kind == .tool_result) and item.turn == 0)) return error.InvalidSessionView;
        return item;
    }
};

fn number(bytes: []const u8) !u64 {
    if (bytes.len == 0 or (bytes.len > 1 and bytes[0] == '0')) return error.InvalidSessionView;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidSessionView;
    const value = try std.fmt.parseInt(u64, bytes, 10);
    if (value > std.math.maxInt(i64)) return error.InvalidSessionView;
    return value;
}

pub fn decode(bytes: []const u8, cursor: Cursor) !Page {
    if (bytes.len > response_bytes) return error.InvalidSessionView;
    const WirePage = struct {
        version: []const u8,
        type: []const u8,
        end: []const u8,
        more: bool,
        pending_total: []const u8,
        action: []const u8,
        work: struct { status: Work.Status, turn: []const u8, operation: []const u8 },
        items: []WireItem,
        pending: []WireItem,
    };
    // Fixed parsing arena expires here; only copied metadata escapes. A
    // malformed oversized shape rejects without a general-heap fallback.
    var storage: [response_bytes * 3]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&storage);
    const wire = try std.json.parseFromSliceLeaky(WirePage, allocator.allocator(), bytes, .{});
    if (!std.mem.eql(u8, wire.version, "1") or !std.mem.eql(u8, wire.type, "session_view") or
        wire.items.len > capacity or wire.pending.len > pending_capacity or (wire.more and wire.items.len == 0) or (cursor.recent and wire.more)) return error.InvalidSessionView;
    var page: Page = .{
        .end = try number(wire.end),
        .more = wire.more,
        .count = wire.items.len,
        .pending_count = wire.pending.len,
        .pending_total = try number(wire.pending_total),
        .action = try number(wire.action),
        .work = .{ .status = wire.work.status, .turn = try number(wire.work.turn), .operation = try number(wire.work.operation) },
    };
    if ((page.work.turn == 0) != (page.work.operation == 0) or
        ((page.work.status == .in_flight or page.work.status == .waiting_for_permission) and page.work.turn == 0)) return error.InvalidSessionView;
    if ((cursor.end != 0 and page.end != cursor.end) or page.end < cursor.position or page.pending_total < page.pending_count) return error.InvalidSessionView;
    var position = cursor.position;
    var ordinal = cursor.ordinal;
    for (wire.items, 0..) |raw, i| {
        const item = try raw.value();
        if (item.position > page.end or item.position < position or (item.position == position and item.ordinal <= ordinal)) return error.InvalidSessionView;
        page.items[i] = item;
        position = item.position;
        ordinal = item.ordinal;
    }
    var message: u64 = 0;
    for (wire.pending, 0..) |raw, i| {
        const item = try raw.value();
        if (item.kind != .admission or item.position > page.end or item.message <= message) return error.InvalidSessionView;
        page.pending[i] = item;
        message = item.message;
    }
    return page;
}

test "Session view continuation advances scanned gaps only after interval drains" {
    var page: Page = .{ .end = 19, .count = 1, .more = true };
    page.items[0] = .{ .position = 12, .ordinal = 3, .kind = .tool_result };
    var cursor = page.continuation(.{});
    try std.testing.expectEqual(Cursor{ .end = 19, .position = 12, .ordinal = 3 }, cursor);
    page.more = false;
    try std.testing.expectEqual(Cursor{ .position = 19 }, page.continuation(cursor));
    page.items[0] = .{ .position = 19, .ordinal = 17, .kind = .tool_result };
    cursor = page.continuation(cursor);
    try std.testing.expectEqual(Cursor{ .position = 19, .ordinal = 17 }, cursor);
    page.count = 0;
    for (0..3) |_| {
        cursor = page.continuation(cursor);
        try std.testing.expectEqual(Cursor{ .position = 19, .ordinal = 17 }, cursor);
    }
    page.end = 23;
    cursor = page.continuation(cursor);
    try std.testing.expectEqual(Cursor{ .position = 23 }, cursor);
    page.end = 29;
    page.count = 1;
    page.items[0] = .{ .position = 29, .kind = .assistant };
    try std.testing.expectEqual(Cursor{ .position = 29 }, page.continuation(cursor));
}
