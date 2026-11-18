const std = @import("std");

pub const Rgb = [3]u8;
pub const Mode = enum { light, dark };
pub const Background = enum { ground, selvedge, user_message, selection, hover, alert };
pub const Text = enum { strong, body, indigo, quiet, attention, failure, on_alert };
pub const Depth = enum { direct, indexed };
pub const Color = union(Depth) { direct: Rgb, indexed: u8 };

const Palette = struct {
    ground: Rgb,
    selvedge: Rgb,
    selection: Rgb,
    strong: Rgb,
    body: Rgb,
    indigo: Rgb,
    quiet: Rgb,
    attention: Rgb,
    failure: Rgb,
    thread: Rgb,
};

const light: Palette = .{
    .ground = .{ 0xf3, 0xee, 0xe2 },
    .selvedge = .{ 0xea, 0xe2, 0xcf },
    .selection = .{ 0xe2, 0xd7, 0xbd },
    .strong = .{ 0x1a, 0x18, 0x14 },
    .body = .{ 0x2f, 0x2b, 0x25 },
    .indigo = .{ 0x1f, 0x2d, 0x6b },
    .quiet = .{ 0x6a, 0x62, 0x53 },
    .attention = .{ 0x7a, 0x52, 0x00 },
    .failure = .{ 0x9e, 0x2b, 0x25 },
    .thread = .{ 0xc4, 0xb8, 0x9c },
};
const dark: Palette = .{
    .ground = .{ 0x1b, 0x21, 0x36 },
    .selvedge = .{ 0x24, 0x2b, 0x45 },
    .selection = .{ 0x30, 0x37, 0x4f },
    .strong = .{ 0xf4, 0xed, 0xdc },
    .body = .{ 0xdd, 0xd5, 0xc3 },
    .indigo = .{ 0xb7, 0xc2, 0xe8 },
    .quiet = .{ 0xa8, 0x9f, 0x8c },
    .attention = .{ 0xe6, 0xb8, 0x4a },
    .failure = .{ 0xe0, 0x8a, 0x72 },
    .thread = .{ 0x4b, 0x53, 0x75 },
};

fn palette(mode: Mode) Palette {
    return switch (mode) {
        .light => light,
        .dark => dark,
    };
}

fn midpoint(a: Rgb, b: Rgb) Rgb {
    var result: Rgb = undefined;
    for (a, b, &result) |x, y, *out| out.* = @intCast((@as(u16, x) + y) / 2);
    return result;
}

pub fn background(mode: Mode, depth: Depth, role: Background) Color {
    const p = palette(mode);
    const rgb = switch (role) {
        .ground => p.ground,
        .selvedge => p.selvedge,
        .user_message => midpoint(p.ground, p.selvedge),
        .selection => p.selection,
        .hover => midpoint(p.selvedge, p.selection),
        .alert => Rgb{ 0xe9, 0xb1, 0x30 },
    };
    return switch (depth) {
        .direct => .{ .direct = rgb },
        .indexed => .{ .indexed = indexed.get(mode).backgrounds.get(role) },
    };
}

pub fn text(mode: Mode, depth: Depth, role: Text, on: Background) Color {
    const p = palette(mode);
    const rgb = switch (role) {
        .strong => p.strong,
        .body => p.body,
        .indigo => p.indigo,
        .quiet => if (mode == .light and (on == .selvedge or on == .selection or on == .hover)) Rgb{ 0x62, 0x5a, 0x4c } else if (mode == .dark and on == .selection) Rgb{ 0xaa, 0xa1, 0x8e } else p.quiet,
        .attention => p.attention,
        .failure => if (mode == .dark and (on == .selection or on == .hover)) Rgb{ 0xeb, 0x9c, 0x84 } else p.failure,
        .on_alert => Rgb{ 0x14, 0x14, 0x14 },
    };
    return switch (depth) {
        .direct => .{ .direct = rgb },
        .indexed => .{ .indexed = indexed.get(mode).texts.get(on).get(role) },
    };
}

pub fn thread(mode: Mode, depth: Depth) Color {
    const rgb = palette(mode).thread;
    return switch (depth) {
        .direct => .{ .direct = rgb },
        .indexed => .{ .indexed = indexed.get(mode).thread },
    };
}

pub fn xtermRgb(index: u8) Rgb {
    std.debug.assert(index >= 16);
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    const n: usize = index - 16;
    return if (index < 232) .{ levels[n / 36], levels[n / 6 % 6], levels[n % 6] } else @splat(@intCast(8 + 10 * (@as(u16, index) - 232)));
}

pub fn relativeLuminance(rgb: Rgb) f64 {
    var result: f64 = 0;
    for (rgb, [_]f64{ 0.2126, 0.7152, 0.0722 }) |byte, weight| {
        const s = @as(f64, @floatFromInt(byte)) / 255.0;
        result += weight * (if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4));
    }
    return result;
}

pub fn nearestIndex(want: Rgb) u8 {
    var best: u8 = 16;
    var distance: u32 = std.math.maxInt(u32);
    for (16..256) |i| {
        const candidate = xtermRgb(@intCast(i));
        var d: u32 = 0;
        for (want, candidate) |a, b| {
            const delta = @as(i32, a) - b;
            d += @intCast(delta * delta);
        }
        if (d < distance) {
            distance = d;
            best = @intCast(i);
        }
    }
    return best;
}

const Indexed = struct {
    backgrounds: std.enums.EnumArray(Background, u8),
    texts: std.enums.EnumArray(Background, std.enums.EnumArray(Text, u8)),
    thread: u8,
};

const indexed = blk: {
    @setEvalBranchQuota(2_000_000);
    var tables = std.enums.EnumArray(Mode, Indexed).initUndefined();
    for (std.enums.values(Mode)) |mode| {
        const table = tables.getPtr(mode);
        for (std.enums.values(Background)) |ground| {
            table.backgrounds.set(ground, nearestIndex(background(mode, .direct, ground).direct));
            var colours = std.enums.EnumArray(Text, u8).initUndefined();
            for (std.enums.values(Text)) |role| {
                colours.set(role, if (mode == .light and role == .attention) 58 else nearestIndex(text(mode, .direct, role, ground).direct));
            }
            table.texts.set(ground, colours);
        }
        table.thread = nearestIndex(palette(mode).thread);
    }
    break :blk tables;
};

pub fn wordmark(utf8: bool, xtversion: ?[]const u8, term_program: ?[]const u8) []const u8 {
    if (!utf8) return "rui";
    if (xtversion) |version| if (version.len != 0) {
        for ([_][]const u8{ "kitty", "ghostty", "wezterm", "iterm2", "apple_terminal" }) |name| {
            if (std.ascii.startsWithIgnoreCase(version, name) and (version.len == name.len or version[name.len] == ' ' or version[name.len] == '(')) return "रुई rui";
        }
        return "rui";
    };
    const program = term_program orelse return "rui";
    for ([_][]const u8{ "kitty", "ghostty", "wezterm", "iTerm.app", "Apple_Terminal" }) |name| {
        if (std.ascii.eqlIgnoreCase(program, name)) return "रुई rui";
    }
    return "rui";
}

test "wordmark requires a known terminal and UTF-8" {
    const cases = [_]struct { version: ?[]const u8, program: ?[]const u8, expected: []const u8 }{
        .{ .version = "kitty(0.35)", .program = null, .expected = "रुई rui" },
        .{ .version = "Ghostty 1.0", .program = null, .expected = "रुई rui" },
        .{ .version = "WezTerm 2024", .program = null, .expected = "रुई rui" },
        .{ .version = "iTerm2 3.5", .program = null, .expected = "रुई rui" },
        .{ .version = null, .program = "Apple_Terminal", .expected = "रुई rui" },
        .{ .version = null, .program = "iTerm.app", .expected = "रुई rui" },
        .{ .version = "", .program = "kitty", .expected = "रुई rui" },
        .{ .version = null, .program = "ghostty", .expected = "रुई rui" },
        .{ .version = null, .program = "WezTerm", .expected = "रुई rui" },
        .{ .version = "xterm 1", .program = "Ghostty", .expected = "rui" },
        .{ .version = "kitty-fake", .program = null, .expected = "rui" },
        .{ .version = null, .program = "Alacritty", .expected = "rui" },
        .{ .version = null, .program = null, .expected = "rui" },
    };
    for (cases) |case| {
        try std.testing.expectEqualStrings(case.expected, wordmark(true, case.version, case.program));
        try std.testing.expectEqualStrings("rui", wordmark(false, case.version, case.program));
    }
}

test "indigo cloth palette and day surfaces" {
    try std.testing.expectEqual(Rgb{ 0x1b, 0x21, 0x36 }, background(.dark, .direct, .ground).direct);
    try std.testing.expectEqual(Rgb{ 0x24, 0x2b, 0x45 }, background(.dark, .direct, .selvedge).direct);
    try std.testing.expectEqual(Rgb{ 0xea, 0xe2, 0xcf }, background(.light, .direct, .selvedge).direct);
    try std.testing.expectEqual(Rgb{ 0x4b, 0x53, 0x75 }, thread(.dark, .direct).direct);
    try std.testing.expectEqual(Rgb{ 0xc4, 0xb8, 0x9c }, thread(.light, .direct).direct);
    const roles = [_]Text{ .strong, .body, .quiet, .indigo, .attention, .failure };
    const colors = [_]Rgb{
        .{ 0xf4, 0xed, 0xdc }, .{ 0xdd, 0xd5, 0xc3 }, .{ 0xa8, 0x9f, 0x8c },
        .{ 0xb7, 0xc2, 0xe8 }, .{ 0xe6, 0xb8, 0x4a }, .{ 0xe0, 0x8a, 0x72 },
    };
    for (roles, colors) |role, color| {
        for ([_]Background{ .ground, .selvedge }) |bg| try std.testing.expectEqual(color, text(.dark, .direct, role, bg).direct);
    }
}

test "selection uses ink wash and hover derives from its neighbouring surfaces" {
    try std.testing.expectEqual(Rgb{ 0xe2, 0xd7, 0xbd }, background(.light, .direct, .selection).direct);
    try std.testing.expectEqual(Rgb{ 0x30, 0x37, 0x4f }, background(.dark, .direct, .selection).direct);
    for (std.enums.values(Mode)) |mode| {
        const bar = background(mode, .direct, .selvedge).direct;
        const selection = background(mode, .direct, .selection).direct;
        const hover = background(mode, .direct, .hover).direct;
        for (bar, selection, hover) |a, b, actual| try std.testing.expectEqual(@as(u8, @intCast((@as(u16, a) + b) / 2)), actual);
    }
}

test "decided indexed pins" {
    try std.testing.expectEqual(@as(u8, 58), text(.light, .indexed, .attention, .ground).indexed);
    try std.testing.expectEqual(@as(u8, 58), text(.light, .indexed, .attention, .selvedge).indexed);
    try std.testing.expectEqual(@as(u8, 187), background(.light, .indexed, .selection).indexed);
    try std.testing.expectEqual(@as(u8, 237), background(.dark, .indexed, .selection).indexed);
    try std.testing.expectEqual(@as(u8, 235), background(.dark, .indexed, .ground).indexed);
    try std.testing.expectEqual(@as(u8, 237), background(.dark, .indexed, .hover).indexed);
    try std.testing.expectEqual(@as(u8, 188), background(.light, .indexed, .hover).indexed);
    try std.testing.expectEqual(Rgb{ 0x62, 0x5a, 0x4c }, text(.light, .direct, .quiet, .selvedge).direct);
    try std.testing.expectEqual(Rgb{ 0x62, 0x5a, 0x4c }, text(.light, .direct, .quiet, .hover).direct);
}

test "indexed colors follow direct colors except the light attention pin" {
    for (std.enums.values(Mode)) |mode| {
        for (std.enums.values(Background)) |bg| {
            try std.testing.expectEqual(nearestIndex(background(mode, .direct, bg).direct), background(mode, .indexed, bg).indexed);
            for (std.enums.values(Text)) |fg| {
                const expected: u8 = if (mode == .light and fg == .attention) 58 else nearestIndex(text(mode, .direct, fg, bg).direct);
                try std.testing.expectEqual(expected, text(mode, .indexed, fg, bg).indexed);
            }
        }
        try std.testing.expectEqual(nearestIndex(thread(mode, .direct).direct), thread(mode, .indexed).indexed);
    }
}

test "nearest xterm index excludes terminal-defined entries" {
    try std.testing.expectEqual(@as(u8, 16), nearestIndex(.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 231), nearestIndex(.{ 255, 255, 255 }));
    try std.testing.expectEqual(@as(u8, 214), nearestIndex(.{ 0xf2, 0xc2, 0x00 }));
}

test "readable text meets WCAG contrast on its layout backgrounds" {
    const Check = struct {
        fn rgb(color: Color) Rgb {
            return switch (color) {
                .direct => |value| value,
                .indexed => |i| xtermRgb(i),
            };
        }
        fn contrast(a: Color, b: Color) f64 {
            const x = relativeLuminance(rgb(a));
            const y = relativeLuminance(rgb(b));
            return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
        }
    };
    for (std.enums.values(Mode)) |mode| for (std.enums.values(Depth)) |depth| {
        for ([_]Background{ .ground, .selvedge, .user_message, .selection, .hover }) |bg| {
            for ([_]Text{ .strong, .body, .indigo, .quiet, .attention, .failure }) |fg| {
                const contrast = Check.contrast(text(mode, depth, fg, bg), background(mode, depth, bg));
                if (contrast < 4.5) std.debug.print("{s} {s}: {s} on {s}: {d:.3}\n", .{ @tagName(mode), @tagName(depth), @tagName(fg), @tagName(bg), contrast });
                try std.testing.expect(contrast >= 4.5);
            }
        }
        try std.testing.expect(Check.contrast(text(mode, depth, .on_alert, .alert), background(mode, depth, .alert)) >= 4.5);
    };
}

test "user message tint is faint cloth distinct from ground in both themes and depths" {
    try std.testing.expectEqual(Rgb{ 0xee, 0xe8, 0xd8 }, background(.light, .direct, .user_message).direct);
    try std.testing.expectEqual(Rgb{ 0x1f, 0x26, 0x3d }, background(.dark, .direct, .user_message).direct);
    try std.testing.expectEqual(@as(u8, 254), background(.light, .indexed, .user_message).indexed);
    try std.testing.expectEqual(@as(u8, 236), background(.dark, .indexed, .user_message).indexed);
    for (std.enums.values(Mode)) |mode| for (std.enums.values(Depth)) |depth| {
        try std.testing.expect(!std.meta.eql(background(mode, depth, .ground), background(mode, depth, .user_message)));
    };
}
