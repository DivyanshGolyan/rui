//! The Connections reference in app settings: a block per served connection with the sign-in it uses and the usage the
//! Host last saw it report, each window drawn as a bar. It is read-only text over host_info's facts, so nothing here reaches the Host.
//! A usage window is named by its length in minutes, never by its slot, because which slot carries which window is the provider's choice.
//! Every row is its own short fact so the longest one still fits the narrowest dialog (40 columns).
const std = @import("std");
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const Panel = @import("widgets/Panel.zig");

const max_line = 96;
/// A name row, a sign-in row, two windows of a bar and a reset row each, and a blank row between connections.
const lines_per_connection = 7;
const max_lines = connection.max_served * lines_per_connection;
const bar_cells = 10;
const max_named_days = 999;
const indent: [24]u8 = @splat(' ');

pub const Rows = struct {
    fields: [max_lines]Panel.Field = undefined,
    lines: [max_lines][max_line]u8 = undefined,
    names: [connection.max_served][connection.max_name_bytes]u8 = undefined,
    len: usize = 0,

    fn add(self: *Rows, label: []const u8, comptime format: []const u8, args: anytype) void {
        var out: std.Io.Writer = .fixed(&self.lines[self.len]);
        out.print(format, args) catch {};
        self.fields[self.len] = .{ .label = label, .value = out.buffered() };
        self.len += 1;
    }

    /// The rows to draw for `facts` at Unix second `now`, in served order, with a blank row between connections.
    pub fn build(rows: *Rows, facts: []const protocol.ConnectionFact, now: u64, unicode: bool) []const Panel.Field {
        rows.len = 0;
        for (facts[0..@min(facts.len, connection.max_served)], 0..) |fact, index| {
            if (index > 0) rows.add("", "", .{});
            const name = fact.name.slice();
            @memcpy(rows.names[index][0..name.len], name);
            rows.add(rows.names[index][0..name.len], "", .{});
            const reading = fact.usage orelse {
                rows.add("", "  {s}", .{fact.label.slice()});
                // A browser sign-in sends no usage headers; any other connection simply has not reported yet.
                rows.add("", "  {s}", .{if (fact.route == .chatgpt_plan) "no usage for browser sign-ins" else "no usage seen yet"});
                continue;
            };
            var age_bytes: [32]u8 = undefined;
            var age: std.Io.Writer = .fixed(&age_bytes);
            writeAge(&age, now -| reading.observed_at) catch {};
            rows.add("", "  {s} {s} {s}", .{ fact.label.slice(), if (unicode) "·" else "-", age.buffered() });
            var widest: usize = 0;
            inline for (.{ reading.primary, reading.secondary }) |maybe| if (maybe) |window| {
                widest = @max(widest, nameWidth(window.minutes));
            };
            inline for (.{ reading.primary, reading.secondary }) |maybe| if (maybe) |window| {
                var bytes: [max_line]u8 = undefined;
                var out: std.Io.Writer = .fixed(&bytes);
                writeBar(&out, window, widest, unicode) catch {};
                rows.add("", "  {s}", .{out.buffered()});
                if (window.reset_at) |at| {
                    var span_bytes: [32]u8 = undefined;
                    var span: std.Io.Writer = .fixed(&span_bytes);
                    writeSpan(&span, at -| now) catch {};
                    rows.add("", "{s}resets in {s}", .{ indent[0 .. 4 + @min(widest, indent.len - 4)], span.buffered() });
                }
            };
        }
        return rows.fields[0..rows.len];
    }
};

fn nameWidth(minutes: u64) usize {
    var bytes: [32]u8 = undefined;
    var out: std.Io.Writer = .fixed(&bytes);
    writeName(&out, minutes) catch unreachable;
    return out.buffered().len;
}

/// `weekly  █████░░░░░  47%`: the window's name padded to `name_width`, a ten-cell bar and the percent used; a window at its limit reads `full`.
fn writeBar(out: *std.Io.Writer, window: protocol.UsageWindow, name_width: usize, unicode: bool) std.Io.Writer.Error!void {
    const start = out.end;
    try writeName(out, window.minutes);
    for (out.end - start..name_width + 2) |_| try out.writeByte(' ');
    const used = std.math.clamp(window.used_percent, 0, 100);
    const filled: usize = @intFromFloat(@round(used / 100.0 * bar_cells));
    for (0..bar_cells) |cell| try out.writeAll(if (cell < filled) (if (unicode) "█" else "#") else (if (unicode) "░" else "-"));
    if (window.used_percent >= 100) {
        try out.writeAll("  full");
    } else {
        try out.print("  {d:.0}%", .{window.used_percent});
    }
}

/// A window's name from its length: the two lengths people know by name, else the length itself.
fn writeName(out: *std.Io.Writer, minutes: u64) std.Io.Writer.Error!void {
    if (minutes == 10080) return out.writeAll("weekly");
    if (minutes == 300) return out.writeAll("5-hour");
    // The longest name a row has room for is `1438559-minute`; a longer window is named only by its order of magnitude.
    if (minutes >= max_named_days * 1440) return out.writeAll("999+ day");
    if (minutes % 1440 == 0) return out.print("{d}-day", .{minutes / 1440});
    if (minutes % 60 == 0) return out.print("{d}-hour", .{minutes / 60});
    return out.print("{d}-minute", .{minutes});
}

/// The two largest whole units of a span: `3 d 4 h`, `2 h 5 m`, `7 m`; a span under a minute reads `< 1 m` and one of 1000 days or more `over 999 d`,
/// so the longest span still fits the row of the longest window name in the narrowest dialog.
fn writeSpan(out: *std.Io.Writer, seconds: u64) std.Io.Writer.Error!void {
    const days = seconds / 86400;
    const hours = seconds % 86400 / 3600;
    const minutes = seconds % 3600 / 60;
    if (days >= 1000) return out.writeAll("over 999 d");
    if (days > 0) return out.print("{d} d {d} h", .{ days, hours });
    if (hours > 0) return out.print("{d} h {d} m", .{ hours, minutes });
    if (minutes > 0) return out.print("{d} m", .{minutes});
    try out.writeAll("< 1 m");
}

fn writeAge(out: *std.Io.Writer, seconds: u64) std.Io.Writer.Error!void {
    if (seconds < 60) return out.writeAll("just now");
    if (seconds >= 100 * 86400) return out.writeAll("over 99 d ago");
    try writeSpan(out, seconds);
    try out.writeAll(" ago");
}

fn served(name: []const u8, label: []const u8, route: protocol.Route, usage: ?protocol.UsageReading) protocol.ConnectionFact {
    return .{ .name = connection.Name.parse(name).?, .label = @import("provider_route.zig").Label.parse(label).?, .route = route, .usage = usage };
}

fn text(field: Panel.Field, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}|{s}", .{ field.label, field.value }) catch unreachable;
}

test "SUI-183 the Connections reference draws each window as a bar named by its length and says when a connection shows no usage" {
    const now: u64 = 1_800_000_000;
    const week: protocol.UsageWindow = .{ .used_percent = 47.4, .minutes = 10080, .reset_at = now + 3 * 86400 + 4 * 3600 + 59 };
    const full: protocol.UsageWindow = .{ .used_percent = 100, .minutes = 300, .reset_at = now + 7 * 60 };
    const odd: protocol.UsageWindow = .{ .used_percent = 3, .minutes = 90, .reset_at = null };
    const facts = [_]protocol.ConnectionFact{
        served("work", "ChatGPT (device code)", .chatgpt_device, .{ .observed_at = now - 12 * 60, .primary = week, .secondary = full }),
        served("home", "ChatGPT", .chatgpt_plan, null),
        served("lab", "ChatGPT (device code)", .chatgpt_device, null),
        served("odd", "ChatGPT (device code)", .chatgpt_device, .{ .observed_at = now - 5, .primary = odd, .secondary = null }),
    };
    const expected = [_][]const u8{
        "work|",
        "|  ChatGPT (device code) · 12 m ago",
        "|  weekly  █████░░░░░  47%",
        "|          resets in 3 d 4 h",
        "|  5-hour  ██████████  full",
        "|          resets in 7 m",
        "|",
        "home|",
        "|  ChatGPT",
        "|  no usage for browser sign-ins",
        "|",
        "lab|",
        "|  ChatGPT (device code)",
        "|  no usage seen yet",
        "|",
        "odd|",
        "|  ChatGPT (device code) · just now",
        "|  90-minute  ░░░░░░░░░░  3%",
    };
    var rows: Rows = .{};
    const shown = rows.build(&facts, now, true);
    try std.testing.expectEqual(expected.len, shown.len);
    var buffer: [128]u8 = undefined;
    for (expected, shown) |want, got| try std.testing.expectEqualStrings(want, text(got, &buffer));
    var ascii: Rows = .{};
    try std.testing.expectEqualStrings("|  weekly  #####-----  47%", text(ascii.build(&facts, now, false)[2], &buffer));
}

test "SUI-183 every Connections row fits the narrowest dialog for the longest name, label and window" {
    const now: u64 = 1_800_000_000;
    // The narrowest settings dialog is 40 columns wide (a 46-column terminal); a row is its own text plus a one-column margin.
    const width = 40;
    const worst: protocol.UsageWindow = .{ .used_percent = 100, .minutes = 14 * 1440 + 60, .reset_at = now + 99 * 86400 + 23 * 3600 };
    // The longest names the minutes domain can produce: the widest named length, the first unnamed one and the largest value.
    const long_minutes: protocol.UsageWindow = .{ .used_percent = 100, .minutes = 999 * 1440 - 1, .reset_at = now + 99 * 86400 + 23 * 3600 };
    const unnamed: protocol.UsageWindow = .{ .used_percent = 0, .minutes = std.math.maxInt(u64), .reset_at = null };
    const facts = [_]protocol.ConnectionFact{
        served("abcdefghijklmnop", "ChatGPT (device code)", .chatgpt_device, .{ .observed_at = now - 400 * 86400, .primary = worst, .secondary = worst }),
        served("x", "ChatGPT", .chatgpt_plan, null),
        served("long", "ChatGPT (device code)", .chatgpt_device, .{ .observed_at = now, .primary = long_minutes, .secondary = unnamed }),
    };
    var rows: Rows = .{};
    for ([_]bool{ true, false }) |unicode| {
        for (rows.build(&facts, now, unicode)) |field| {
            var cells: usize = 0;
            var each = std.unicode.Utf8View.initUnchecked(field.value).iterator();
            while (each.nextCodepoint()) |_| cells += 1;
            if (!unicode) for (field.value) |byte| try std.testing.expect(byte < 0x80);
            try std.testing.expect(1 + field.label.len + (if (field.label.len > 0 and field.value.len > 0) @as(usize, 3) else 0) + cells <= width);
        }
    }
}

test "SUI-183 a reset row fits the narrowest dialog for every window name against every reset span" {
    const now: u64 = 1_800_000_000;
    const lengths = [_]u64{ 300, 10080, 90, 999 * 1440 - 1, 999 * 1440, std.math.maxInt(u64) };
    const resets = [_]?u64{ null, 0, now - 5, now, now + 59, now + 3600, now + 99 * 86400 + 23 * 3600, now + 5000 * 86400, std.math.maxInt(u64) };
    var rows: Rows = .{};
    for (lengths) |minutes| for (resets) |reset_at| for ([_]bool{ true, false }) |unicode| {
        const window: protocol.UsageWindow = .{ .used_percent = 100, .minutes = minutes, .reset_at = reset_at };
        const facts = [_]protocol.ConnectionFact{served("abcdefghijklmnop", "ChatGPT (device code)", .chatgpt_device, .{ .observed_at = now, .primary = window, .secondary = window })};
        for (rows.build(&facts, now, unicode)) |field| {
            var cells: usize = 0;
            var each = std.unicode.Utf8View.initUnchecked(field.value).iterator();
            while (each.nextCodepoint()) |_| cells += 1;
            try std.testing.expect(1 + field.label.len + (if (field.label.len > 0 and field.value.len > 0) @as(usize, 3) else 0) + cells <= 40);
        }
    };
}
