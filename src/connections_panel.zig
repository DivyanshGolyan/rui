//! The Connections reference in app settings: one row per served connection, with the sign-in it uses and the
//! usage the Host last saw it report. It is read-only text over host_info's facts, so nothing here reaches the Host.
//! A usage window is named by its length in minutes, never by its slot, because which slot carries which window is the provider's choice.
const std = @import("std");
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const Panel = @import("widgets/Panel.zig");

const max_line = 96;
const lines_per_connection = 4;
const max_lines = connection.max_served * lines_per_connection;

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
};

/// The rows to draw for `facts` at Unix second `now`, in served order. Each connection takes a row with its name and sign-in,
/// then one row per usage window, then one row for how old the reading is, so every row fits a narrow screen.
pub fn build(rows: *Rows, facts: []const protocol.ConnectionFact, now: u64) []const Panel.Field {
    rows.len = 0;
    for (facts[0..@min(facts.len, connection.max_served)], 0..) |fact, index| {
        const name = fact.name.slice();
        @memcpy(rows.names[index][0..name.len], name);
        rows.add(rows.names[index][0..name.len], "{s}", .{fact.label.slice()});
        const reading = fact.usage orelse {
            // A browser sign-in sends no usage headers; any other connection simply has not reported yet.
            rows.add("", "{s}", .{if (fact.route == .chatgpt_plan) "no usage for browser sign-ins" else "no usage seen yet"});
            continue;
        };
        inline for (.{ reading.primary, reading.secondary }) |maybe| if (maybe) |window| {
            var buffer: [max_line]u8 = undefined;
            var out: std.Io.Writer = .fixed(&buffer);
            writeWindow(&out, window, now) catch {};
            rows.add("", "{s}", .{out.buffered()});
        };
        var buffer: [max_line]u8 = undefined;
        var out: std.Io.Writer = .fixed(&buffer);
        writeAge(&out, now -| reading.observed_at) catch {};
        rows.add("", "as of {s}", .{out.buffered()});
    }
    return rows.fields[0..rows.len];
}

fn writeWindow(out: *std.Io.Writer, window: protocol.UsageWindow, now: u64) std.Io.Writer.Error!void {
    try writeName(out, window.minutes);
    if (window.used_percent >= 100) {
        try out.writeAll(" limit reached");
    } else {
        try out.print(" {d:.0}% used", .{window.used_percent});
    }
    if (window.reset_at) |at| {
        try out.writeAll(" · resets in ");
        try writeSpan(out, at -| now);
    }
}

/// A window's name from its length: the two lengths people know by name, else the length itself.
fn writeName(out: *std.Io.Writer, minutes: u64) std.Io.Writer.Error!void {
    if (minutes == 10080) return out.writeAll("weekly");
    if (minutes == 300) return out.writeAll("5-hour");
    if (minutes % 1440 == 0) return out.print("{d}-day", .{minutes / 1440});
    if (minutes % 60 == 0) return out.print("{d}-hour", .{minutes / 60});
    return out.print("{d}-minute", .{minutes});
}

/// The two largest whole units of a span: `3 d 4 h`, `2 h 5 m`, `7 m`; a span under a minute reads `under a minute`.
fn writeSpan(out: *std.Io.Writer, seconds: u64) std.Io.Writer.Error!void {
    const days = seconds / 86400;
    const hours = seconds % 86400 / 3600;
    const minutes = seconds % 3600 / 60;
    if (days > 0) return out.print("{d} d {d} h", .{ days, hours });
    if (hours > 0) return out.print("{d} h {d} m", .{ hours, minutes });
    if (minutes > 0) return out.print("{d} m", .{minutes});
    try out.writeAll("under a minute");
}

fn writeAge(out: *std.Io.Writer, seconds: u64) std.Io.Writer.Error!void {
    if (seconds < 60) return out.writeAll("just now");
    try writeSpan(out, seconds);
    try out.writeAll(" ago");
}

fn served(name: []const u8, label: []const u8, route: protocol.Route, usage: ?protocol.UsageReading) protocol.ConnectionFact {
    return .{ .name = connection.Name.parse(name).?, .label = @import("provider_route.zig").Label.parse(label).?, .route = route, .usage = usage };
}

test "SUI-182 the Connections reference names each window by its length and says when a connection shows no usage" {
    const now: u64 = 1_800_000_000;
    const week: protocol.UsageWindow = .{ .used_percent = 25.4, .minutes = 10080, .reset_at = now + 3 * 86400 + 4 * 3600 + 59 };
    const full: protocol.UsageWindow = .{ .used_percent = 100, .minutes = 300, .reset_at = now + 7 * 60 };
    const odd: protocol.UsageWindow = .{ .used_percent = 3, .minutes = 90, .reset_at = null };
    const facts = [_]protocol.ConnectionFact{
        served("work", "ChatGPT (device code)", .chatgpt_device, .{ .observed_at = now - 12 * 60, .primary = week, .secondary = full }),
        served("home", "ChatGPT", .chatgpt_plan, null),
        served("lab", "ChatGPT (device code)", .chatgpt_device, null),
        served("odd", "ChatGPT (device code)", .chatgpt_device, .{ .observed_at = now - 5, .primary = odd, .secondary = null }),
    };
    var rows: Rows = .{};
    const shown = build(&rows, &facts, now);
    const expected = [_][2][]const u8{
        .{ "work", "ChatGPT (device code)" },
        .{ "", "weekly 25% used · resets in 3 d 4 h" },
        .{ "", "5-hour limit reached · resets in 7 m" },
        .{ "", "as of 12 m ago" },
        .{ "home", "ChatGPT" },
        .{ "", "no usage for browser sign-ins" },
        .{ "lab", "ChatGPT (device code)" },
        .{ "", "no usage seen yet" },
        .{ "odd", "ChatGPT (device code)" },
        .{ "", "90-minute 3% used" },
        .{ "", "as of just now" },
    };
    try std.testing.expectEqual(expected.len, shown.len);
    for (expected, shown) |want, got| {
        try std.testing.expectEqualStrings(want[0], got.label);
        try std.testing.expectEqualStrings(want[1], got.value);
    }
}
