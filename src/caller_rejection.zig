//! CLI protocol adapter: shared saved tags have one catalog identity.
const std = @import("std");
const protocol = @import("protocol.zig");
const caller_error = @import("caller_error.zig");
const Code = caller_error.Code;
const names = caller_error.names;

/// Every wire rejection vocabulary the CLI can decode. Recovery uses these
/// same reply enums; it has no separate rejection spelling. Proposal tags are
/// saved conversation facts, not re-rendered CLI errors, but share coverage.
const rejection_enums = .{
    protocol.ConfigurationRejection,     protocol.MessageRejection,
    protocol.SessionStopRejection,       protocol.SessionArchiveRejection,
    protocol.ModelInterruptionRejection, protocol.PermissionDecisionRejection,
    protocol.ProposalRejection,
};

pub fn fromProtocol(rejection: anytype) Code {
    return switch (rejection) {
        inline else => |tag| @field(Code, @tagName(tag)),
    };
}

pub fn fromRejection(text: []const u8) ?Code {
    inline for (rejection_enums) |E| {
        if (std.meta.stringToEnum(E, text)) |tag| return fromProtocol(tag);
    }
    return null;
}

comptime {
    @setEvalBranchQuota(100_000);
    for (rejection_enums) |E| for (names(E)) |tag| {
        if (!@hasField(Code, tag)) @compileError("protocol rejection needs caller facts: " ++ tag);
        if (fromProtocol(@field(E, tag)) != @field(Code, tag)) @compileError("rejection must map to exactly one Code: " ++ tag);
    };
    for (rejection_enums) |E| for (names(E)) |tag| {
        _ = caller_error.facts(@field(Code, tag));
    };
}

test "every saved protocol rejection maps to exactly one catalog code" {
    inline for (rejection_enums) |E| inline for (comptime std.meta.tags(E)) |tag| {
        const code = fromProtocol(tag);
        try std.testing.expectEqual(code, fromRejection(@tagName(tag)).?);
        try std.testing.expectEqualStrings(@tagName(tag), @tagName(code));
    };
    try std.testing.expectEqual(@as(?Code, null), fromRejection("future_rejection"));
    try std.testing.expectEqual(@as(?Code, null), fromRejection("choice_unsupported"));
}
