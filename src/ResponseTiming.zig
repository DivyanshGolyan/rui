const ResponseTiming = @This();

/// One inactivity rule for every exchange: 60 seconds without positive byte
/// progress ends it. A request kind chooses only whether that rule also bounds
/// the silent wait before the first response byte.
inactivity_ms: i32 = 60_000,
wait_for_first_byte: bool = true,

pub const transfer: ResponseTiming = .{};
/// A mutation's admission answer is due after upload, so its silent first-byte
/// phase is bounded by the same inactivity as every transfer.
pub const mutation: ResponseTiming = .{ .wait_for_first_byte = false };

pub fn deadline(self: ResponseTiming, now: i128, absolute: ?i128, progressed: bool) ?i128 {
    if (absolute) |until| return until;
    if (!progressed and self.wait_for_first_byte) return null;
    return now + @as(i128, self.inactivity_ms) * 1_000_000;
}

test "every response kind shares one inactivity and only mutations bound the silent first byte" {
    const testing = @import("std").testing;
    const second = 1_000_000_000;
    const cases = [_]struct { timing: ResponseTiming, progressed: bool, expected: ?i128 }{
        .{ .timing = mutation, .progressed = false, .expected = 67 * second },
        .{ .timing = mutation, .progressed = true, .expected = 67 * second },
        .{ .timing = transfer, .progressed = false, .expected = null },
        .{ .timing = transfer, .progressed = true, .expected = 67 * second },
    };
    for (cases) |case| {
        try testing.expectEqual(case.expected, case.timing.deadline(7 * second, null, case.progressed));
        for ([_]i128{ 8 * second, 7 * second, 6 * second }) |absolute|
            try testing.expectEqual(absolute, case.timing.deadline(7 * second, absolute, case.progressed).?);
    }
}

test "a mutation answer after five seconds is still inside its wait and one silent past sixty is not" {
    const testing = @import("std").testing;
    const second = 1_000_000_000;
    const uploaded = 7 * second;
    const due = mutation.deadline(uploaded, null, false).?;
    for ([_]i128{ 5, 6, 30, 59 }) |after| try testing.expect(uploaded + after * second < due);
    for ([_]i128{ 60, 61 }) |after| try testing.expect(uploaded + after * second >= due);
}

test "positive progress renews mutation inactivity without a total response deadline" {
    const testing = @import("std").testing;
    const second = 1_000_000_000;
    try testing.expectEqual(67 * second, mutation.deadline(7 * second, null, false).?);
    try testing.expectEqual(71 * second, mutation.deadline(11 * second, null, true).?);
    try testing.expectEqual(75 * second, mutation.deadline(15 * second, null, true).?);
}
