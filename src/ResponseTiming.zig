//! Response deadlines from caller-supplied awake-clock nanoseconds. The socket
//! owner samples time only after positive progress; retrying a read keeps its
//! original deadline. This module owns no clock or transport resources.
const ResponseTiming = @This();

inactivity_ms: i32 = 60_000,
wait_for_first_byte: bool = true,

pub const mutation: ResponseTiming = .{ .inactivity_ms = 5_000, .wait_for_first_byte = false };

pub fn deadline(self: ResponseTiming, now: i128, absolute: ?i128, progressed: bool) ?i128 {
    if (absolute) |until| return until;
    if (!progressed and self.wait_for_first_byte) return null;
    return now + @as(i128, self.inactivity_ms) * 1_000_000;
}

test "response policy separates mutation silence transfer inactivity and discovery" {
    const testing = @import("std").testing;
    const second = 1_000_000_000;
    const cases = [_]struct { timing: ResponseTiming, progressed: bool, expected: ?i128 }{
        .{ .timing = mutation, .progressed = false, .expected = 12 * second },
        .{ .timing = mutation, .progressed = true, .expected = 12 * second },
        .{ .timing = .{}, .progressed = false, .expected = null },
        .{ .timing = .{}, .progressed = true, .expected = 67 * second },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, case.timing.deadline(7 * second, null, case.progressed));
        // Discovery never renews, even when its absolute deadline has elapsed.
        for ([_]i128{ 8 * second, 7 * second, 6 * second }) |absolute|
            try testing.expectEqual(absolute, case.timing.deadline(7 * second, absolute, case.progressed).?);
    }
}

test "positive progress renews mutation inactivity without a total response deadline" {
    const testing = @import("std").testing;
    const second = 1_000_000_000;
    // A response starting at 7s and progressing at 11s and 15s can finish at
    // 19s. A total five-second deadline or a nonrenewing body would reject it.
    try testing.expectEqual(12 * second, mutation.deadline(7 * second, null, false).?);
    try testing.expectEqual(16 * second, mutation.deadline(11 * second, null, true).?);
    try testing.expectEqual(20 * second, mutation.deadline(15 * second, null, true).?);
}
