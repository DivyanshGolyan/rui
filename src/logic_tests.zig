const std = @import("std");
const core_boundary = @import("core_boundary.zig");

/// Functional cores: decisions over values that their shells interpret.
/// `core_boundary.zig` defines what a core may name; the test below checks
/// each one listed here and runs its tests, and selector tests require each
/// to select test-logic.
const cores = .{
    .{ "attempt.zig", @import("attempt.zig") },
    .{ "BashLifecycle.zig", @import("BashLifecycle.zig") },
    .{ "bounded.zig", @import("bounded.zig") },
    .{ "change_ring.zig", @import("change_ring.zig") },
    .{ "ChoiceLine.zig", @import("ChoiceLine.zig") },
    .{ "cli_args.zig", @import("cli_args.zig") },
    .{ "codex_credential_policy.zig", @import("codex_credential_policy.zig") },
    .{ "codex_token_wire.zig", @import("codex_token_wire.zig") },
    .{ "deadline.zig", @import("deadline.zig") },
    .{ "descriptor_capacity.zig", @import("descriptor_capacity.zig") },
    .{ "json_ascii.zig", @import("json_ascii.zig") },
    .{ "model_capability.zig", @import("model_capability.zig") },
    .{ "product_defaults.zig", @import("product_defaults.zig") },
    .{ "provider_selection.zig", @import("provider_selection.zig") },
    .{ "retry_policy.zig", @import("retry_policy.zig") },
    .{ "session_consent.zig", @import("session_consent.zig") },
    .{ "session_departure.zig", @import("session_departure.zig") },
    .{ "session_work.zig", @import("session_work.zig") },
    .{ "transport_policy.zig", @import("transport_policy.zig") },
    .{ "turn_policy.zig", @import("turn_policy.zig") },
};

test {
    _ = @import("AnswerRenderer.zig");
    _ = @import("core_boundary.zig");
    _ = @import("execution.zig");
    _ = @import("execution_turn.zig");
    _ = @import("history_memo.zig");
    _ = @import("named_scratch.zig");
    _ = @import("new_session_selection.zig");
    _ = @import("request_encoding.zig");
    _ = @import("ResponseTiming.zig");
    _ = @import("ConversationViewport.zig");
    _ = @import("SessionInput.zig");
    _ = @import("TerminalFrame.zig");
    _ = @import("TerminalInput.zig");
    _ = @import("TerminalEditor.zig");
    _ = @import("TerminalText.zig");
    _ = @import("terminal_input_equivalence_test.zig");
    _ = @import("tools.zig");
    inline for (cores) |core| _ = core[1];
}

test "functional cores stay within the core boundary" {
    const names = comptime blk: {
        var list: [cores.len][]const u8 = undefined;
        for (cores, 0..) |core, index| list[index] = core[0];
        break :blk list;
    };
    inline for (cores) |core| {
        // The checked source is the imported one.
        try std.testing.expectEqualStrings(core[0], @typeName(core[1]) ++ ".zig");
        if (core_boundary.check(@embedFile(core[0]), &names)) |violation| {
            std.debug.print("{s}:{d}: `{s}` is outside the core boundary; see src/core_boundary.zig\n", .{ core[0], violation.line, violation.text });
            return error.CoreBoundaryViolation;
        }
    }
}

test "the HTTP/2 client's proxy logic stays within the core boundary" {
    // A core of the self-contained h2 module, as its policy is.
    if (core_boundary.check(@embedFile("h2/proxy.zig"), &.{})) |violation| {
        std.debug.print("h2/proxy.zig:{d}: `{s}` is outside the core boundary; see src/core_boundary.zig\n", .{ violation.line, violation.text });
        return error.CoreBoundaryViolation;
    }
}

test "the HTTP/2 client's policy stays within the core boundary" {
    // A core of the self-contained h2 module: test-h2 runs its tests, and it
    // may import no Rui core.
    if (core_boundary.check(@embedFile("h2/policy.zig"), &.{})) |violation| {
        std.debug.print("h2/policy.zig:{d}: `{s}` is outside the core boundary; see src/core_boundary.zig\n", .{ violation.line, violation.text });
        return error.CoreBoundaryViolation;
    }
}
