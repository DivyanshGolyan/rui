const std = @import("std");

/// Copy selection lifecycle only. Coordinates, selection ranges, links and UI effects
/// remain owned by their adapters.
pub const Phase = enum { idle, pressed, dragging, cancelled };

/// Facts the transcript adapter derives before asking for the next transition.
pub const Input = union(enum) {
    press,
    drag: bool, // true only when this event moved away from the press cell
    cancel,
    motion,
    release: bool, // true when the raw release remains on the press cell
};

pub const Effect = enum {
    none,
    begin,
    restart,
    start_drag,
    update_drag,
    cancel,
    finish_click,
    finish_copy,
    consume_drag,
    consume_release,
    retire,
};

pub const Step = struct { phase: Phase, effect: Effect };

/// Pure value transition. The caller stores only the returned phase and applies its effect.
pub fn step(phase: Phase, input: Input) Step {
    return switch (phase) {
        .idle => switch (input) {
            .press => .{ .phase = .pressed, .effect = .begin },
            else => .{ .phase = .idle, .effect = .none },
        },
        .pressed => switch (input) {
            .press => .{ .phase = .pressed, .effect = .restart },
            .drag => |moved| if (moved)
                .{ .phase = .dragging, .effect = .start_drag }
            else
                .{ .phase = .pressed, .effect = .none },
            .cancel => .{ .phase = .cancelled, .effect = .cancel },
            .motion => .{ .phase = .idle, .effect = .retire },
            .release => |same_cell| .{ .phase = .idle, .effect = if (same_cell) .finish_click else .finish_copy },
        },
        .dragging => switch (input) {
            .press => .{ .phase = .pressed, .effect = .restart },
            .drag => .{ .phase = .dragging, .effect = .update_drag },
            .cancel => .{ .phase = .cancelled, .effect = .cancel },
            .motion => .{ .phase = .idle, .effect = .retire },
            .release => .{ .phase = .idle, .effect = .finish_copy },
        },
        .cancelled => switch (input) {
            .press => .{ .phase = .pressed, .effect = .restart },
            .drag => .{ .phase = .cancelled, .effect = .consume_drag },
            .cancel => .{ .phase = .cancelled, .effect = .none },
            // Supported mouse protocols emit no-button motion only after the
            // physical button is no longer held; retire stale custody.
            .motion => .{ .phase = .idle, .effect = .retire },
            .release => .{ .phase = .idle, .effect = .consume_release },
        },
    };
}

test "SUI-159 copy gesture transitions exhaust phases and consume canceled releases" {
    const Case = struct { phase: Phase, input: Input, expected: Step };
    const cases = [_]Case{
        .{ .phase = .idle, .input = .press, .expected = .{ .phase = .pressed, .effect = .begin } },
        .{ .phase = .idle, .input = .{ .drag = false }, .expected = .{ .phase = .idle, .effect = .none } },
        .{ .phase = .idle, .input = .{ .drag = true }, .expected = .{ .phase = .idle, .effect = .none } },
        .{ .phase = .idle, .input = .cancel, .expected = .{ .phase = .idle, .effect = .none } },
        .{ .phase = .idle, .input = .motion, .expected = .{ .phase = .idle, .effect = .none } },
        .{ .phase = .idle, .input = .{ .release = false }, .expected = .{ .phase = .idle, .effect = .none } },
        .{ .phase = .idle, .input = .{ .release = true }, .expected = .{ .phase = .idle, .effect = .none } },
        .{ .phase = .pressed, .input = .press, .expected = .{ .phase = .pressed, .effect = .restart } },
        .{ .phase = .pressed, .input = .{ .drag = false }, .expected = .{ .phase = .pressed, .effect = .none } },
        .{ .phase = .pressed, .input = .{ .drag = true }, .expected = .{ .phase = .dragging, .effect = .start_drag } },
        .{ .phase = .pressed, .input = .cancel, .expected = .{ .phase = .cancelled, .effect = .cancel } },
        .{ .phase = .pressed, .input = .motion, .expected = .{ .phase = .idle, .effect = .retire } },
        .{ .phase = .pressed, .input = .{ .release = false }, .expected = .{ .phase = .idle, .effect = .finish_copy } },
        .{ .phase = .pressed, .input = .{ .release = true }, .expected = .{ .phase = .idle, .effect = .finish_click } },
        .{ .phase = .dragging, .input = .press, .expected = .{ .phase = .pressed, .effect = .restart } },
        .{ .phase = .dragging, .input = .{ .drag = false }, .expected = .{ .phase = .dragging, .effect = .update_drag } },
        .{ .phase = .dragging, .input = .{ .drag = true }, .expected = .{ .phase = .dragging, .effect = .update_drag } },
        .{ .phase = .dragging, .input = .cancel, .expected = .{ .phase = .cancelled, .effect = .cancel } },
        .{ .phase = .dragging, .input = .motion, .expected = .{ .phase = .idle, .effect = .retire } },
        .{ .phase = .dragging, .input = .{ .release = false }, .expected = .{ .phase = .idle, .effect = .finish_copy } },
        .{ .phase = .dragging, .input = .{ .release = true }, .expected = .{ .phase = .idle, .effect = .finish_copy } },
        .{ .phase = .cancelled, .input = .press, .expected = .{ .phase = .pressed, .effect = .restart } },
        .{ .phase = .cancelled, .input = .{ .drag = false }, .expected = .{ .phase = .cancelled, .effect = .consume_drag } },
        .{ .phase = .cancelled, .input = .{ .drag = true }, .expected = .{ .phase = .cancelled, .effect = .consume_drag } },
        .{ .phase = .cancelled, .input = .cancel, .expected = .{ .phase = .cancelled, .effect = .none } },
        .{ .phase = .cancelled, .input = .motion, .expected = .{ .phase = .idle, .effect = .retire } },
        .{ .phase = .cancelled, .input = .{ .release = false }, .expected = .{ .phase = .idle, .effect = .consume_release } },
        .{ .phase = .cancelled, .input = .{ .release = true }, .expected = .{ .phase = .idle, .effect = .consume_release } },
    };
    for (cases) |case| try std.testing.expectEqualDeep(case.expected, step(case.phase, case.input));

    const cancelled = step(.dragging, .cancel);
    try std.testing.expectEqual(Phase.cancelled, cancelled.phase);
    try std.testing.expectEqual(Effect.cancel, cancelled.effect);

    const consumed_drag = step(cancelled.phase, .{ .drag = true });
    try std.testing.expectEqual(Phase.cancelled, consumed_drag.phase);
    try std.testing.expectEqual(Effect.consume_drag, consumed_drag.effect);

    const consumed_release = step(consumed_drag.phase, .{ .release = false });
    try std.testing.expectEqual(Phase.idle, consumed_release.phase);
    try std.testing.expectEqual(Effect.consume_release, consumed_release.effect);

    const fresh = step(consumed_release.phase, .press);
    try std.testing.expectEqual(Phase.pressed, fresh.phase);
    try std.testing.expectEqual(Effect.begin, fresh.effect);

    const cancelled_again = step(.dragging, .cancel);
    const restarted = step(cancelled_again.phase, .press);
    try std.testing.expectEqual(Phase.pressed, restarted.phase);
    try std.testing.expectEqual(Effect.restart, restarted.effect);
    const restarted_release = step(restarted.phase, .{ .release = true });
    try std.testing.expectEqual(Phase.idle, restarted_release.phase);
    try std.testing.expectEqual(Effect.finish_click, restarted_release.effect);
}
