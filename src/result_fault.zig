//! Fault decisions for the shared tool-result settlement route.
const std = @import("std");
const media = @import("input_media.zig");

pub const Failure = union(enum) {
    source: anyerror,
    capture: anyerror,
    store: anyerror,
};

pub const Fault = enum { rejected, storage_full, superseded, suppressed, uncertain };
pub const storage_failed_text = "The Host's scratch storage filled while saving this result.";

/// Source errors describe input; unexpected capture and Store errors leave the
/// result uncertain. Seal failures are fenced at the adapter boundary.
pub fn classify(failure: Failure) Fault {
    const err = switch (failure) {
        inline else => |value| value,
    };
    switch (err) {
        error.SupersededByControl => return .superseded,
        error.HostDispatchSuppressed => return .suppressed,
        else => {},
    }
    return switch (failure) {
        .source => .rejected,
        .store => .uncertain,
        .capture => blk: {
            if (err == error.ScratchCapacityExceeded) break :blk .storage_full;
            if (err == error.ImageFileChanged or err == error.InvalidBase64) break :blk .rejected;
            inline for (@typeInfo(media.Error).error_set.error_names.?) |name| {
                if (err == @field(anyerror, name)) break :blk .rejected;
            }
            break :blk .uncertain;
        },
    };
}

test "media, capacity and control errors across origins" {
    inline for (@typeInfo(media.Error).error_set.error_names.?) |name| {
        const err = @field(anyerror, name);
        try std.testing.expectEqual(Fault.rejected, classify(.{ .source = err }));
        try std.testing.expectEqual(Fault.rejected, classify(.{ .capture = err }));
        try std.testing.expectEqual(Fault.uncertain, classify(.{ .store = err }));
    }
    inline for (.{ error.ImageFileChanged, error.InvalidBase64 }) |err| {
        try std.testing.expectEqual(Fault.rejected, classify(.{ .source = err }));
        try std.testing.expectEqual(Fault.rejected, classify(.{ .capture = err }));
        try std.testing.expectEqual(Fault.uncertain, classify(.{ .store = err }));
    }
    try std.testing.expectEqual(Fault.rejected, classify(.{ .source = error.ScratchCapacityExceeded }));
    try std.testing.expectEqual(Fault.storage_full, classify(.{ .capture = error.ScratchCapacityExceeded }));
    try std.testing.expectEqual(Fault.uncertain, classify(.{ .store = error.ScratchCapacityExceeded }));
    inline for (.{ .{ error.SupersededByControl, Fault.superseded }, .{ error.HostDispatchSuppressed, Fault.suppressed } }) |case| {
        try std.testing.expectEqual(case[1], classify(.{ .source = case[0] }));
        try std.testing.expectEqual(case[1], classify(.{ .capture = case[0] }));
        try std.testing.expectEqual(case[1], classify(.{ .store = case[0] }));
    }
    try std.testing.expectEqual(Fault.uncertain, classify(.{ .capture = error.UnexpectedFault }));
}
