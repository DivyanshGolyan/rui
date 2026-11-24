const std = @import("std");
const vaxis = @import("vaxis");
const view = @import("overview_view.zig");
const theme = @import("theme.zig");

const stitch = @import("widgets/Stitch.zig");

pub const Line = stitch.Line;

/// The one cell every rule and divider draws: a running stitch in the thread colour.
pub fn line(caps: view.Caps, which: Line) vaxis.Cell {
    return stitch.cell(caps.unicode, which, of(caps, .{ .colour = .rule }));
}

test "line stitches use thread in every capability" {
    for ([_]?view.Rgb{ null, .{ 255, 255, 255 } }) |background| {
        for (std.enums.values(view.Caps.Depth)) |depth| for ([_]bool{ false, true }) |unicode| for (std.enums.values(Line)) |which| {
            const caps: view.Caps = .{ .depth = depth, .unicode = unicode, .background = background };
            const cell = line(caps, which);
            const glyph = switch (which) {
                .horizontal => if (unicode) "┄" else "-",
                .vertical => if (unicode) "┆" else "|",
            };
            try std.testing.expectEqualStrings(glyph, cell.char.grapheme);
            try std.testing.expectEqual(1, cell.char.width);
            const expected: vaxis.Color = if (depth == .none) .default else switch (theme.thread(if (background == null) .dark else .light, if (depth == .direct) .direct else .indexed)) {
                .direct => |rgb| .{ .rgb = rgb },
                .indexed => |index| .{ .index = index },
            };
            try std.testing.expectEqual(expected, cell.style.fg);
        };
    }
}

/// How a screen covered by a dialog draws: every cell in the thread colour on the scrim, a
/// ground darker than the cloth, so the raised card above it stands apart (a dimmed screen and
/// a lifted surface, as dialogs separate in dark and light themes). Without colour it is faint.
pub fn backdrop(caps: view.Caps) vaxis.Style {
    return if (caps.depth == .none) .{ .dim = true } else of(caps, .{ .colour = .rule, .background = .scrim });
}

test "backdrop is the thread on a scrim darker than the ground and the raised card, or faint without colour" {
    for ([_]?view.Rgb{ null, .{ 255, 255, 255 } }) |background| for (std.enums.values(view.Caps.Depth)) |depth| {
        const caps: view.Caps = .{ .depth = depth, .background = background };
        const style = backdrop(caps);
        if (depth == .none) {
            try std.testing.expectEqual(vaxis.Style{ .dim = true }, style);
            continue;
        }
        try std.testing.expectEqual(line(caps, .horizontal).style.fg, style.fg);
        try std.testing.expect(!style.bold and !style.reverse);
        const lum = struct {
            fn of_(color: vaxis.Color) f64 {
                return theme.relativeLuminance(switch (color) {
                    .rgb => |value| value,
                    .index => |i| theme.xtermRgb(i),
                    else => unreachable,
                });
            }
        }.of_;
        const scrim = lum(style.bg);
        const ground = lum(of(caps, .{}).bg);
        const raised = lum(of(caps, .{ .background = .raised }).bg);
        try std.testing.expect(scrim < ground);
        try std.testing.expect(scrim < raised);
        // Indexed day cloth gives the raised card the ground's entry rather than pure white.
        try std.testing.expect(if (depth == .direct) raised > ground else raised >= ground);
    };
}

/// The colour for the terminal's own background (OSC 11), which also fills the window padding and
/// the leftover strips no cell covers: the RGB the ground cells show, at every colour depth, so the
/// edges always match. Without colour the terminal keeps its own background.
pub fn terminalGround(caps: view.Caps) ?view.Rgb {
    if (caps.depth == .none) return null;
    return switch (of(caps, .{}).bg) {
        .rgb => |value| value,
        // Entries 16-255 are the xterm palette every 256-colour terminal shares.
        .index => |index| theme.xtermRgb(index),
        else => unreachable,
    };
}

test "the terminal's own background is the RGB the ground cells show at every depth and skin" {
    for ([_]?view.Rgb{ null, .{ 255, 255, 255 } }) |background| for (std.enums.values(view.Caps.Depth)) |depth| {
        const caps: view.Caps = .{ .depth = depth, .background = background };
        const ground = terminalGround(caps);
        switch (depth) {
            .none => try std.testing.expectEqual(null, ground),
            .direct => try std.testing.expectEqual(of(caps, .{}).bg, vaxis.Color{ .rgb = ground.? }),
            .indexed => {
                const index = of(caps, .{}).bg.index;
                try std.testing.expect(index >= 16);
                try std.testing.expectEqual(theme.xtermRgb(index), ground.?);
            },
        }
    };
}

const DimCache = struct {
    const Entry = struct { key: u64 = 0, value: vaxis.Color = .default, valid: bool = false };
    entries: [256]Entry = @splat(.{}),
};

/// Restyle the pane's frame-local buffers in place to preserve its live hit tree.
pub fn dimSurface(surface: vaxis.vxfw.Surface, monochrome: bool) void {
    var result = surface;
    var cache: DimCache = .{};
    dimTree(&result, monochrome, &cache);
}

fn dimTree(surface: *vaxis.vxfw.Surface, monochrome: bool, cache: *DimCache) void {
    for (surface.buffer) |*cell| {
        if (cell.default) continue;
        const style = &cell.style;
        if (monochrome) {
            if (!style.bold and !style.reverse and !style.dim and style.ul_style == .off) style.dim = true;
        } else if (!style.dim and style.bg != .default and style.fg != .default) {
            dimColored(style, cache);
        }
    }
    for (surface.children) |*child| dimTree(&child.surface, monochrome, cache);
}

fn dimColored(style: *vaxis.Style, cache: *DimCache) void {
    const foreground = if (style.reverse) style.bg else style.fg;
    const background = if (style.reverse) style.fg else style.bg;
    const fg = colorRgb(foreground) orelse return;
    const bg = colorRgb(background) orelse return;
    const key: u64 = (@as(u64, colorKey(foreground)) << 32) | colorKey(background);
    const slot = @as(usize, @intCast((key ^ (key >> 17) ^ (key >> 31)) & 255));
    const entry = &cache.entries[slot];
    var selected = foreground;
    if (entry.valid and entry.key == key) {
        selected = entry.value;
    } else {
        const original_contrast = contrastRatio(fg, bg);
        if (original_contrast >= 4.5) {
            const target = blend(fg, bg, 0.18);
            const adjusted = if (contrastRatio(target, bg) >= 4.5) target else floorBlend(fg, bg);
            switch (foreground) {
                .rgb => selected = .{ .rgb = adjusted },
                .index => {
                    const quantized = theme.nearestIndex(adjusted);
                    const quantized_rgb = theme.xtermRgb(quantized);
                    const quantized_contrast = contrastRatio(quantized_rgb, bg);
                    if (quantized_contrast >= 4.5 and quantized_contrast < original_contrast) selected = .{ .index = quantized };
                },
                .default => {},
            }
        }
        entry.* = .{ .key = key, .value = selected, .valid = true };
    }
    if (style.reverse) style.bg = selected else style.fg = selected;
}

fn floorBlend(fg: [3]u8, bg: [3]u8) [3]u8 {
    var low: f64 = 0;
    var high: f64 = 0.18;
    for (0..8) |_| {
        const middle = (low + high) / 2;
        if (contrastRatio(blend(fg, bg, middle), bg) >= 4.5) low = middle else high = middle;
    }
    return blend(fg, bg, low);
}

fn colorKey(color: vaxis.Color) u32 {
    return switch (color) {
        .default => 0,
        .index => |index| (@as(u32, 1) << 24) | index,
        .rgb => |rgb| (@as(u32, 2) << 24) | pack(rgb),
    };
}

fn blend(fg: [3]u8, bg: [3]u8, amount: f64) [3]u8 {
    var result: [3]u8 = undefined;
    for (fg, bg, &result) |front, back, *out| out.* = @intFromFloat(@round(@as(f64, @floatFromInt(front)) * (1 - amount) + @as(f64, @floatFromInt(back)) * amount));
    return result;
}

fn contrastRatio(fg: [3]u8, bg: [3]u8) f64 {
    const a = theme.relativeLuminance(fg);
    const b = theme.relativeLuminance(bg);
    return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
}

fn pack(rgb: [3]u8) u24 {
    return (@as(u24, rgb[0]) << 16) | (@as(u24, rgb[1]) << 8) | rgb[2];
}

fn colorRgb(color: vaxis.Color) ?[3]u8 {
    return switch (color) {
        .rgb => |rgb| rgb,
        .index => |index| if (index < 16) null else theme.xtermRgb(index),
        .default => null,
    };
}

test "SUI-4 inactive pane dimming preserves cell data, contrast floor, reverse and monochrome cues" {
    const vx = @import("vaxis");
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const widget = vx.vxfw.Widget{ .userdata = undefined, .drawFn = undefined };
    var parent = try vx.vxfw.Surface.init(arena.allocator(), widget, .{ .width = 1, .height = 1 });
    const child_widget = vx.vxfw.Widget{ .userdata = @ptrFromInt(1), .drawFn = undefined };
    var child = try vx.vxfw.Surface.init(arena.allocator(), child_widget, .{ .width = 4, .height = 1 });
    child.buffer[0] = .{ .char = .{ .grapheme = "x", .width = 1 }, .style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bg = .{ .rgb = .{ 0, 0, 0 } }, .ul = .{ .rgb = .{ 1, 2, 3 } }, .ul_style = .single }, .link = .{ .uri = "https://example.test" }, .wrapped = true };
    child.buffer[1] = .{ .char = .{ .grapheme = "r", .width = 1 }, .style = .{ .fg = .{ .rgb = .{ 100, 100, 100 } }, .bg = .{ .rgb = .{ 110, 110, 110 } } } };
    child.buffer[2] = .{ .char = .{ .grapheme = "v", .width = 1 }, .style = .{ .fg = .{ .rgb = .{ 255, 255, 255 } }, .bg = .{ .rgb = .{ 0, 0, 0 } }, .reverse = true } };
    parent.children = try arena.allocator().alloc(vx.vxfw.SubSurface, 1);
    parent.children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = child };
    dimSurface(parent, false);
    const drawn = parent.children[0].surface;
    try std.testing.expectEqualStrings("x", drawn.buffer[0].char.grapheme);
    try std.testing.expectEqualStrings("https://example.test", drawn.buffer[0].link.uri);
    try std.testing.expect(drawn.buffer[0].wrapped and drawn.buffer[0].style.ul_style == .single);
    try std.testing.expectEqual(vx.Color{ .rgb = .{ 1, 2, 3 } }, drawn.buffer[0].style.ul);
    try std.testing.expectEqual(@as(u8, 209), drawn.buffer[0].style.fg.rgb[0]);
    try std.testing.expectEqual(@as(u8, 100), drawn.buffer[1].style.fg.rgb[0]);
    try std.testing.expect(drawn.buffer[2].style.reverse);
    try std.testing.expectEqual(@as(u8, 46), drawn.buffer[2].style.bg.rgb[0]);

    drawn.buffer[0].style = .{ .fg = .{ .index = 231 }, .bg = .{ .index = 16 } };
    dimSurface(parent, false);
    try std.testing.expect(drawn.buffer[0].style.fg == .index);
    try std.testing.expect(drawn.buffer[0].style.fg.index != 231);
    const indexed_fg = theme.xtermRgb(drawn.buffer[0].style.fg.index);
    try std.testing.expect(contrastRatio(indexed_fg, theme.xtermRgb(16)) >= 4.5);
    drawn.buffer[0].style = .{ .fg = .{ .index = 7 }, .bg = .{ .index = 16 } };
    dimSurface(parent, false);
    try std.testing.expectEqual(vx.Color{ .index = 7 }, drawn.buffer[0].style.fg);

    drawn.buffer[0] = .{ .char = .{ .grapheme = "m" }, .style = .{} };
    drawn.buffer[1].style = .{ .bold = true };
    drawn.buffer[2].style = .{ .reverse = true };
    drawn.buffer[3] = .{ .default = true };
    dimSurface(parent, true);
    try std.testing.expect(drawn.buffer[0].style.dim);
    try std.testing.expect(drawn.buffer[1].style.bold and !drawn.buffer[1].style.dim);
    try std.testing.expect(drawn.buffer[2].style.reverse and !drawn.buffer[2].style.dim);
    try std.testing.expect(!drawn.buffer[3].style.dim);
}

// The returned segments and their text borrow the frame arena and the input, respectively.
pub fn segments(arena: std.mem.Allocator, caps: view.Caps, input: []const view.Segment, background: ?view.Background) std.mem.Allocator.Error![]vaxis.Segment {
    const result = try arena.alloc(vaxis.Segment, input.len);
    for (input, result) |segment, *dest| {
        var role = segment.style;
        if (background) |value| role.background = value;
        dest.* = .{ .text = segment.text, .style = of(caps, role) };
    }
    return result;
}

test "segments preserve roles unless a background is supplied" {
    const input = [_]view.Segment{
        .{ .text = "one", .style = .{ .colour = .failure, .background = .band, .bold = true } },
        .{ .text = " two", .style = .{ .colour = .quiet, .background = .hover, .dim = true } },
    };
    for (std.enums.values(view.Caps.Depth)) |depth| for ([_]?view.Background{ null, .selection, .hover }) |background| {
        const caps: view.Caps = .{ .depth = depth };
        const converted = try segments(std.testing.allocator, caps, &input, background);
        defer std.testing.allocator.free(converted);
        for (input, converted) |source, actual| {
            var role = source.style;
            if (background) |value| role.background = value;
            try std.testing.expectEqualStrings(source.text, actual.text);
            try std.testing.expectEqualDeep(of(caps, role), actual.style);
        }
    };
}

pub fn of(caps: view.Caps, role: view.Style) vaxis.Style {
    var style: vaxis.Style = .{ .bold = role.bold, .reverse = role.reverse, .dim = role.dim };
    if (caps.depth == .none) {
        style.bold = role.bold or role.background == .band;
        style.reverse = role.reverse or role.background == .band or role.background == .selection;
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
        .bar, .input_surface => .selvedge,
        .user_message => .user_message,
        .selection => .selection,
        .hover => .hover,
        .band => .alert,
        .raised => .raised,
        .scrim => .scrim,
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
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0xeb, 0x9c, 0x84 } }, night.fg);
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0x30, 0x37, 0x4f } }, night.bg);
    try std.testing.expect(night.bold);
    const indexed = of(.{ .depth = .indexed }, .{ .colour = .strong });
    try std.testing.expectEqual(vaxis.Color{ .index = 255 }, indexed.fg);
    try std.testing.expectEqual(vaxis.Color{ .index = 235 }, indexed.bg);
    const selvedge = of(.{ .background = .{ 255, 255, 255 } }, .{ .colour = .quiet, .background = .bar });
    try std.testing.expectEqual(vaxis.Color{ .rgb = .{ 0x62, 0x5a, 0x4c } }, selvedge.fg);
    const attention = of(.{ .depth = .indexed, .background = .{ 255, 255, 255 } }, .{ .colour = .attention, .background = .bar });
    try std.testing.expectEqual(vaxis.Color{ .index = 58 }, attention.fg);
    for ([_]view.Caps.Depth{ .direct, .indexed, .none }) |depth| {
        try std.testing.expect(of(.{ .depth = depth }, .{ .dim = true }).dim);
        try std.testing.expect(!of(.{ .depth = depth }, .{}).dim);
    }
    const selected = of(.{ .depth = .indexed }, .{ .background = .selection });
    try std.testing.expectEqual(vaxis.Color{ .index = 238 }, selected.bg);
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
            for ([_]view.Background{ .ground, .bar, .input_surface, .selection }) |surface| {
                try std.testing.expect(!std.meta.eql(of(caps, .{ .background = surface }).bg, hover.bg));
            }
        }
    }
}

test "input surface stays distinct from ink wash selection in both themes and depths" {
    for ([_]?view.Rgb{ .{ 255, 255, 255 }, null }) |terminal| {
        for ([_]view.Caps.Depth{ .direct, .indexed }) |depth| {
            const caps: view.Caps = .{ .depth = depth, .background = terminal };
            const input = of(caps, .{ .background = .input_surface });
            try std.testing.expect(!std.meta.eql(input.bg, of(caps, .{ .background = .selection }).bg));
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
            const expected_fg: u8 = if (terminal != null and colour == .attention) 58 else if (terminal == null and ground == .selection and (colour == .quiet or colour == .mark)) 249 else Check.nearest(direct.fg.rgb);
            const expected_bg: u8 = if (terminal == null and ground == .selection) 238 else if (terminal != null and ground == .raised) Check.nearest(of(.{ .background = terminal }, .{}).bg.rgb) else Check.nearest(direct.bg.rgb);
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
                .index => |i| theme.xtermRgb(i),
                else => unreachable,
            };
        }
        fn check(caps: view.Caps, role: view.Style) !void {
            const style = of(caps, role);
            const a = theme.relativeLuminance(rgb(style.fg));
            const b = theme.relativeLuminance(rgb(style.bg));
            const contrast = (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
            if (contrast < 4.5) std.debug.print("{s} {s} on {s}: {d:.3}\n", .{ @tagName(caps.depth), @tagName(role.colour), @tagName(role.background), contrast });
            try std.testing.expect(contrast >= 4.5);
        }
    };
    for ([_]?view.Rgb{ .{ 255, 255, 255 }, null }) |terminal| {
        for ([_]view.Caps.Depth{ .direct, .indexed }) |depth| {
            const caps: view.Caps = .{ .depth = depth, .background = terminal };
            for ([_]view.Background{ .ground, .bar, .input_surface, .selection, .hover, .raised }) |ground| {
                for ([_]view.Colour{ .strong, .ink, .normal, .quiet, .mark, .attention, .failure }) |colour| {
                    try Check.check(caps, .{ .colour = colour, .background = ground });
                }
            }
            try Check.check(caps, .{ .colour = .on_band, .background = .band });
        }
    }
}
