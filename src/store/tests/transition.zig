const shared_fixtures = @import("../tests.zig");
const std = @import("std");
const protocol = @import("../../protocol.zig");
const change_ring = @import("../../change_ring.zig");
const store_core = @import("../Store.zig");
const transition = @import("../transition.zig");
const rsql = @import("../rsql.zig");
const content_domain = @import("../domain/content.zig");
const store_testing = @import("../testing.zig");
test "a transition's rounds run in declared order and only a paged round repeats" {
    const R = transition.rounds(.{
        .a = .{ .always, error.TestingRead },
        .b = .{ .paged, error.TestingRead },
        .c = .{ .branch, error.TestingRead },
    });
    const At = R.At;
    const cases = [_]struct { last: ?At, allowed: [3]bool }{
        .{ .last = null, .allowed = .{ true, true, true } },
        .{ .last = .a, .allowed = .{ false, true, true } },
        .{ .last = .b, .allowed = .{ false, true, true } },
        .{ .last = .c, .allowed = .{ false, false, false } },
    };
    for (cases) |row| for ([_]At{ .a, .b, .c }, row.allowed) |next, allowed| {
        try std.testing.expectEqual(allowed, R.follows(row.last, next));
    };
}
