const std = @import("std");

pub const Rgb = [3]u8;
pub const Mode = enum { light, dark };
pub const Background = enum { ground, selvedge, selection, hover, alert };
pub const Text = enum { strong, body, indigo, quiet, attention, failure, on_alert };
pub const Depth = enum { direct, indexed };
pub const Color = union(Depth) { direct: Rgb, indexed: u8 };

const Palette = struct {
    ground: Rgb,
    selvedge: Rgb,
    selection: Rgb,
    /// Per-channel midpoint of selvedge and selection: a pointer's row, quieter than the keyboard's.
    hover: Rgb,
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
    .selvedge = .{ 0xe6, 0xdd, 0xc8 },
    .selection = .{ 0xdd, 0xe0, 0xee },
    .hover = .{ 0xe1, 0xde, 0xdb },
    .strong = .{ 0x1a, 0x18, 0x14 },
    .body = .{ 0x2f, 0x2b, 0x25 },
    .indigo = .{ 0x1f, 0x2d, 0x6b },
    .quiet = .{ 0x6a, 0x62, 0x53 },
    .attention = .{ 0x7a, 0x52, 0x00 },
    .failure = .{ 0x9e, 0x2b, 0x25 },
    .thread = .{ 0xd3, 0xc8, 0xb0 },
};
const dark: Palette = .{
    .ground = .{ 0x12, 0x19, 0x33 },
    .selvedge = .{ 0x1a, 0x22, 0x46 },
    .selection = .{ 0x2a, 0x34, 0x67 },
    .hover = .{ 0x22, 0x2b, 0x56 },
    .strong = .{ 0xf2, 0xec, 0xdf },
    .body = .{ 0xd4, 0xce, 0xbf },
    .indigo = .{ 0xa9, 0xb6, 0xec },
    .quiet = .{ 0xa2, 0xa3, 0xbc },
    .attention = .{ 0xef, 0xb9, 0x3c },
    .failure = .{ 0xf0, 0x8b, 0x74 },
    .thread = .{ 0x2d, 0x37, 0x62 },
};

fn palette(mode: Mode) Palette {
    return switch (mode) {
        .light => light,
        .dark => dark,
    };
}

pub fn background(mode: Mode, depth: Depth, role: Background) Color {
    const p = palette(mode);
    const rgb = switch (role) {
        .ground => p.ground,
        .selvedge => p.selvedge,
        .selection => p.selection,
        .hover => p.hover,
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
        // Quiet text darkens on the day selvedge and hover to keep 4.5:1.
        .quiet => if (mode == .light and (on == .selvedge or on == .hover)) Rgb{ 0x62, 0x5a, 0x4c } else p.quiet,
        .attention => p.attention,
        .failure => p.failure,
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

/// Nearest xterm cube or grey-ramp entry; terminal-defined entries 0–15 are excluded.
pub fn nearestIndex(want: Rgb) u8 {
    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
    var best: u8 = 16;
    var distance: u32 = std.math.maxInt(u32);
    for (16..256) |i| {
        const candidate: Rgb = if (i < 232) .{ levels[(i - 16) / 36], levels[(i - 16) / 6 % 6], levels[(i - 16) % 6] } else @splat(@intCast(8 + 10 * (i - 232)));
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

/// The xterm grey ramp has no step between selvedge and selection in either skin, so the
/// nearest hover entries (237 night, 253 day) would repeat them. Night hover takes 235,
/// between ground and selvedge, a step from both and quieter than selection on each. Day
/// hover takes white 231, lifting a row where selection darkens it; the darker free grey
/// 252 would fail 4.5:1 under the pinned attention 58 and stand out more than selection.
fn pinnedBackground(mode: Mode, role: Background) ?u8 {
    return switch (role) {
        .selection => if (mode == .dark) 237 else null,
        .hover => switch (mode) {
            .dark => 235,
            .light => 231,
        },
        else => null,
    };
}

const indexed = blk: {
    @setEvalBranchQuota(2_000_000);
    var tables = std.enums.EnumArray(Mode, Indexed).initUndefined();
    for (std.enums.values(Mode)) |mode| {
        const table = tables.getPtr(mode);
        for (std.enums.values(Background)) |ground| {
            table.backgrounds.set(ground, pinnedBackground(mode, ground) orelse nearestIndex(background(mode, .direct, ground).direct));
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

/// A nonempty XTVERSION is authoritative even when it is unrecognised.
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

test "decided indexed pins" {
    try std.testing.expectEqual(@as(u8, 58), text(.light, .indexed, .attention, .ground).indexed);
    try std.testing.expectEqual(@as(u8, 58), text(.light, .indexed, .attention, .selvedge).indexed);
    try std.testing.expectEqual(@as(u8, 237), background(.dark, .indexed, .selection).indexed);
    try std.testing.expectEqual(@as(u8, 234), background(.dark, .indexed, .ground).indexed);
    try std.testing.expectEqual(@as(u8, 235), background(.dark, .indexed, .hover).indexed);
    try std.testing.expectEqual(@as(u8, 231), background(.light, .indexed, .hover).indexed);
    try std.testing.expectEqual(Rgb{ 0x62, 0x5a, 0x4c }, text(.light, .direct, .quiet, .selvedge).direct);
    try std.testing.expectEqual(Rgb{ 0x62, 0x5a, 0x4c }, text(.light, .direct, .quiet, .hover).direct);
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
                .indexed => |i| if (i < 232) blk: {
                    const levels = [_]u8{ 0, 95, 135, 175, 215, 255 };
                    const n: usize = i - 16;
                    break :blk .{ levels[n / 36], levels[n / 6 % 6], levels[n % 6] };
                } else @splat(@intCast(8 + 10 * (@as(u16, i) - 232))),
            };
        }
        fn luminance(c: Rgb) f64 {
            var result: f64 = 0;
            for (c, [_]f64{ 0.2126, 0.7152, 0.0722 }) |byte, weight| {
                const s = @as(f64, @floatFromInt(byte)) / 255.0;
                result += weight * (if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4));
            }
            return result;
        }
        fn contrast(a: Color, b: Color) f64 {
            const x = luminance(rgb(a));
            const y = luminance(rgb(b));
            return (@max(x, y) + 0.05) / (@min(x, y) + 0.05);
        }
    };
    for (std.enums.values(Mode)) |mode| for (std.enums.values(Depth)) |depth| {
        for ([_]Background{ .ground, .selvedge, .selection, .hover }) |bg| {
            for ([_]Text{ .strong, .body, .indigo, .quiet, .attention, .failure }) |fg| {
                const contrast = Check.contrast(text(mode, depth, fg, bg), background(mode, depth, bg));
                if (contrast < 4.5) std.debug.print("{s} {s}: {s} on {s}: {d:.3}\n", .{ @tagName(mode), @tagName(depth), @tagName(fg), @tagName(bg), contrast });
                try std.testing.expect(contrast >= 4.5);
            }
        }
        try std.testing.expect(Check.contrast(text(mode, depth, .on_alert, .alert), background(mode, depth, .alert)) >= 4.5);
    };
}
