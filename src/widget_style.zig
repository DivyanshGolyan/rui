//! Bind the existing colour roles to vaxis cells. The palette and terminal
//! capability policy stay in the value core, including its indexed tables.
const std = @import("std");
const vaxis = @import("vaxis");
const view = @import("overview_view.zig");

pub fn of(caps: view.Caps, role: view.Style) vaxis.Style {
    var style: vaxis.Style = .{ .bold = role.bold, .reverse = role.reverse };
    switch (caps.depth) {
        .none => {
            style.bold = role.bold or role.background == .band;
            style.reverse = role.background == .band or role.background == .selection;
        },
        .indexed => {
            const palette = view.indexed.get(caps.skin());
            style.fg = .{ .index = palette.colours.get(role.colour) };
            style.bg = .{ .index = palette.backgrounds.get(role.background) };
        },
        .direct => {
            const palette = view.palettes.get(caps.skin());
            style.fg = .{ .rgb = palette.colours.get(role.colour) };
            style.bg = .{ .rgb = palette.backgrounds.get(role.background) };
        },
    }
    return style;
}

test "widget styles keep existing day night indexed and NO_COLOR roles" {
    // Fixed palette values, independent of the lookup used by `of`.
    const day = of(.{ .background = .{ 255, 255, 255 } }, .{ .colour = .ink });
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0x1d, 0x2a, 0x63 } }, day.fg);
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0xf3, 0xee, 0xe2 } }, day.bg);
    const night = of(.{}, .{ .colour = .failure, .background = .selection, .bold = true });
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0xff, 0x8f, 0x7d } }, night.fg);
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0x2b, 0x35, 0x68 } }, night.bg);
    try std.testing.expect(night.bold);
    const indexed = of(.{ .depth = .indexed }, .{ .colour = .strong });
    try std.testing.expectEqual(vaxis.Color{ .index = 255 }, indexed.fg);
    try std.testing.expectEqual(vaxis.Color{ .index = 234 }, indexed.bg);
    for (std.enums.values(view.Colour)) |colour| for (std.enums.values(view.Background)) |background| {
        const plain = of(.{ .depth = .none }, .{ .colour = colour, .background = background });
        try std.testing.expectEqual(vaxis.Color.default, plain.fg);
        try std.testing.expectEqual(vaxis.Color.default, plain.bg);
        try std.testing.expectEqual(background == .band, plain.bold);
        try std.testing.expectEqual(background == .band or background == .selection, plain.reverse);
    };
}
