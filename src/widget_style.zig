//! Bind screen colour roles to the shared theme and vaxis cells.
const std = @import("std");
const vaxis = @import("vaxis");
const view = @import("overview_view.zig");
const theme = @import("theme.zig");

/// The sole terminal-capability normalization boundary for semantic styles.
pub fn of(caps: view.Caps, role: view.Style) vaxis.Style {
    var style: vaxis.Style = .{ .bold = role.bold, .reverse = role.reverse, .dim = role.dim };
    if (caps.depth == .none) {
        style.bold = role.bold or role.background == .band;
        style.reverse = role.reverse or role.background == .band or role.background == .selection;
        // Reverse marks the keyboard's row; the pointer's row only underlines.
        if (role.background == .hover) style.ul_style = .single;
        return style;
    }
    const mode: theme.Mode = switch (caps.skin()) {
        .day => .light,
        .night => .dark,
    };
    const depth: theme.Depth = switch (caps.depth) {
        .none => unreachable,
        .indexed => .indexed,
        .direct => .direct,
    };
    const background: theme.Background = switch (role.background) {
        .ground => .ground,
        .bar => .selvedge,
        .selection => .selection,
        .hover => .hover,
        .band => .alert,
    };
    const fg: theme.Color = switch (role.colour) {
        .strong => theme.text(mode, depth, .strong, background),
        .ink => theme.text(mode, depth, .indigo, background),
        .normal => theme.text(mode, depth, .body, background),
        .quiet, .mark => theme.text(mode, depth, .quiet, background),
        .rule => theme.thread(mode, depth),
        .attention => theme.text(mode, depth, .attention, background),
        .failure => theme.text(mode, depth, .failure, background),
        .on_band => theme.text(mode, depth, .on_alert, background),
    };
    style.fg = switch (fg) {
        .direct => |rgb| .{ .rgb = rgb },
        .indexed => |index| .{ .index = index },
    };
    style.bg = switch (theme.background(mode, depth, background)) {
        .direct => |rgb| .{ .rgb = rgb },
        .indexed => |index| .{ .index = index },
    };
    return style;
}

test "widget styles resolve theme colours and preserve NO_COLOR" {
    const day = of(.{ .background = .{ 255, 255, 255 } }, .{ .colour = .ink });
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0x1f, 0x2d, 0x6b } }, day.fg);
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0xf3, 0xee, 0xe2 } }, day.bg);
    const night = of(.{}, .{ .colour = .failure, .background = .selection, .bold = true });
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0xf0, 0x8b, 0x74 } }, night.fg);
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0x2a, 0x34, 0x67 } }, night.bg);
    try std.testing.expect(night.bold);
    const indexed = of(.{ .depth = .indexed }, .{ .colour = .strong });
    try std.testing.expectEqual(vaxis.Color{ .index = 255 }, indexed.fg);
    try std.testing.expectEqual(vaxis.Color{ .index = 234 }, indexed.bg);
    const selvedge = of(.{ .background = .{ 255, 255, 255 } }, .{ .colour = .quiet, .background = .bar });
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0x62, 0x5a, 0x4c } }, selvedge.fg);
    const attention = of(.{ .depth = .indexed, .background = .{ 255, 255, 255 } }, .{ .colour = .attention, .background = .bar });
    try std.testing.expectEqual(vaxis.Color{ .index = 58 }, attention.fg);
    for ([_]view.Caps.Depth{ .direct, .indexed, .none }) |depth| {
        try std.testing.expect(of(.{ .depth = depth }, .{ .dim = true }).dim);
        try std.testing.expect(!of(.{ .depth = depth }, .{}).dim);
    }
    const selected = of(.{ .depth = .indexed }, .{ .background = .selection });
    try std.testing.expectEqual(vaxis.Color{ .index = 237 }, selected.bg);
    for (std.enums.values(view.Colour)) |colour| for (std.enums.values(view.Background)) |background| {
        for ([_]bool{ false, true }) |bold| for ([_]bool{ false, true }) |reverse| for ([_]bool{ false, true }) |dim| {
            const plain = of(.{ .depth = .none }, .{ .colour = colour, .background = background, .bold = bold, .reverse = reverse, .dim = dim });
            try std.testing.expectEqual(vaxis.Color.default, plain.fg);
            try std.testing.expectEqual(vaxis.Color.default, plain.bg);
            try std.testing.expectEqual(bold or background == .band, plain.bold);
            try std.testing.expectEqual(reverse or background == .band or background == .selection, plain.reverse);
            try std.testing.expectEqual(dim, plain.dim);
            try std.testing.expectEqual(if (background == .hover) vaxis.Style.Underline.single else .off, plain.ul_style);
        };
    };
}

test "hover differs from the ground, bar and selection it sits beside in every skin and depth" {
    for ([_]?view.Rgb{ .{ 255, 255, 255 }, null }) |terminal| {
        for ([_]view.Caps.Depth{ .direct, .indexed, .none }) |depth| {
            const caps: view.Caps = .{ .depth = depth, .background = terminal };
            const hover = of(caps, .{ .background = .hover });
            if (depth == .none) {
                try std.testing.expectEqual(vaxis.Style.Underline.single, hover.ul_style);
                try std.testing.expect(!hover.reverse);
                try std.testing.expect(of(caps, .{ .background = .selection }).reverse);
                continue;
            }
            try std.testing.expectEqual(vaxis.Style.Underline.off, hover.ul_style);
            for ([_]view.Background{ .ground, .bar, .selection }) |surface| {
                try std.testing.expect(!std.meta.eql(of(caps, .{ .background = surface }).bg, hover.bg));
            }
        }
    }
}

test "widget indexed colours use nearest xterm entries and decided pins" {
    const Check = struct {
        fn nearest(want: [3]u8) u8 {
            const levels = [_]i32{ 0, 95, 135, 175, 215, 255 };
            var best: u8 = 16;
            var best_distance: i32 = std.math.maxInt(i32);
            for (16..256) |i| {
                const rgb: [3]i32 = if (i < 232)
                    .{ levels[(i - 16) / 36], levels[(i - 16) / 6 % 6], levels[(i - 16) % 6] }
                else
                    @splat(@as(i32, @intCast(8 + 10 * (i - 232))));
                var distance: i32 = 0;
                for (want, rgb) |a, b| {
                    const delta = @as(i32, a) - b;
                    distance += delta * delta;
                }
                if (distance < best_distance) {
                    best_distance = distance;
                    best = @intCast(i);
                }
            }
            return best;
        }
    };
    for ([_]?view.Rgb{ .{ 255, 255, 255 }, null }) |terminal| {
        for (std.enums.values(view.Background)) |ground| for (std.enums.values(view.Colour)) |colour| {
            const role: view.Style = .{ .colour = colour, .background = ground };
            const direct = of(.{ .background = terminal }, role);
            const indexed = of(.{ .depth = .indexed, .background = terminal }, role);
            const expected_fg: u8 = if (terminal != null and colour == .attention) 58 else Check.nearest(direct.fg.rgb);
            const expected_bg: u8 = switch (ground) {
                .selection => if (terminal == null) 237 else Check.nearest(direct.bg.rgb),
                .hover => if (terminal == null) 235 else 231,
                else => Check.nearest(direct.bg.rgb),
            };
            try std.testing.expectEqual(vaxis.Color{ .index = expected_fg }, indexed.fg);
            try std.testing.expectEqual(vaxis.Color{ .index = expected_bg }, indexed.bg);
        };
    }
}

test "widget text meets WCAG contrast on each used ground" {
    const Check = struct {
        fn rgb(color: vaxis.Color) [3]u8 {
            return switch (color) {
                .rgb => |value| value,
                .index => |i| if (i < 232) blk: {
                    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
                    const n: usize = i - 16;
                    break :blk .{ levels[n / 36], levels[n / 6 % 6], levels[n % 6] };
                } else @splat(@intCast(8 + 10 * (@as(u16, i) - 232))),
                else => unreachable,
            };
        }
        fn luminance(c: [3]u8) f64 {
            var result: f64 = 0;
            for (c, [_]f64{ 0.2126, 0.7152, 0.0722 }) |byte, weight| {
                const s = @as(f64, @floatFromInt(byte)) / 255;
                result += weight * (if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4));
            }
            return result;
        }
        fn check(caps: view.Caps, role: view.Style) !void {
            const style = of(caps, role);
            const a = luminance(rgb(style.fg));
            const b = luminance(rgb(style.bg));
            const contrast = (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
            if (contrast < 4.5) std.debug.print("{s} {s} on {s}: {d:.3}\n", .{ @tagName(caps.depth), @tagName(role.colour), @tagName(role.background), contrast });
            try std.testing.expect(contrast >= 4.5);
        }
    };
    for ([_]?view.Rgb{ .{ 255, 255, 255 }, null }) |terminal| {
        for ([_]view.Caps.Depth{ .direct, .indexed }) |depth| {
            const caps: view.Caps = .{ .depth = depth, .background = terminal };
            for ([_]view.Background{ .ground, .bar, .selection, .hover }) |ground| {
                for ([_]view.Colour{ .strong, .ink, .normal, .quiet, .mark, .attention, .failure }) |colour| {
                    try Check.check(caps, .{ .colour = colour, .background = ground });
                }
            }
            try Check.check(caps, .{ .colour = .on_band, .background = .band });
        }
    }
}
