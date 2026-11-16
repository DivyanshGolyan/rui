const std = @import("std");
const store_id = @import("store_id.zig");

pub const Kind = enum { sqlite, mysql };

pub fn resolveKind(selector: []const u8, runtime_hint: ?[]const u8) Kind {
    return if (store_id.valid(selector) and runtime_hint != null) .mysql else .sqlite;
}

test "Store target selection retains path semantics without an explicit runtime hint" {
    for ([_][]const u8{ "/sqlite/store", "relative-store", "0123456789abcdef0123456789abcdeF", "", "0123456789abcdef0123456789abcdef" }) |selector| {
        try std.testing.expectEqual(.sqlite, resolveKind(selector, null));
    }
    for ([_][]const u8{ "/runtime", "relative", "" }) |hint| {
        try std.testing.expectEqual(.mysql, resolveKind("0123456789abcdef0123456789abcdef", hint));
        try std.testing.expectEqual(.sqlite, resolveKind("/sqlite/store", hint));
        try std.testing.expectEqual(.sqlite, resolveKind("0123456789abcdef0123456789abcdeF", hint));
    }
}
