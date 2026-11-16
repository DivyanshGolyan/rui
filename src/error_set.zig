const std = @import("std");

pub fn Of(comptime function: anytype) type {
    return @typeInfo(@typeInfo(@TypeOf(function)).@"fn".return_type.?).error_union.error_set;
}

test "Of names a function's returned error set" {
    const Sample = struct {
        fn run(fail: bool) error{ Refused, Missing }!u8 {
            return if (fail) error.Refused else 1;
        }
    };
    try std.testing.expect(Of(Sample.run) == error{ Refused, Missing });
}
