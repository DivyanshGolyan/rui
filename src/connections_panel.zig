//! The Connections reference in app settings: one row per served connection, with the sign-in it uses and the
//! usage the Host last saw it report. It is read-only text over host_info's facts, so nothing here reaches the Host.
//! A usage window is named by its length in minutes, never by its slot, because which slot carries which window is the provider's choice.
const std = @import("std");
const connection = @import("connection.zig");
const protocol = @import("protocol.zig");
const Panel = @import("widgets/Panel.zig");

const max_line = 160;

pub const Rows = struct {
    fields: [connection.max_served]Panel.Field = undefined,
    lines: [connection.max_served][max_line]u8 = undefined,
    names: [connection.max_served][connection.max_name_bytes]u8 = undefined,
};

/// The rows to draw for `facts` at Unix second `now`, in served order.
pub fn build(rows: *Rows, facts: []const protocol.ConnectionFact, now: u64) []const Panel.Field {
    const count = @min(facts.len, rows.fields.len);
    for (facts[0..count], 0..) |fact, index| {
        const name = fact.name.slice();
        @memcpy(rows.names[index][0..name.len], name);
        rows.fields[index] = .{ .label = rows.names[index][0..name.len], .value = line(&rows.lines[index], fact, now) };
    }
    return rows.fields[0..count];
}

fn line(buffer: *[max_line]u8, fact: protocol.ConnectionFact, now: u64) []const u8 {
    var out: std.Io.Writer = .fixed(buffer);
    write(&out, fact, now) catch {};
    return out.buffered();
}

fn write(out: *std.Io.Writer, fact: protocol.ConnectionFact, now: u64) std.Io.Writer.Error!void {
    try out.writeAll(fact.label.slice());
    const reading = fact.usage orelse {
        // A browser sign-in sends no usage headers; any other connection simply has not reported yet.
        try out.writeAll(if (fact.route == .chatgpt_plan) " · usage not shown for browser sign-ins" else " · no usage seen yet");
        return;
    };
    inline for (.{ reading.primary, reading.secondary }) |maybe| if (maybe) |window| try writeWindow(out, window, now);
    try out.writeAll(" · as of ");
    try writeAge(out, now -| reading.observed_at);
}

fn writeWindow(out: *std.Io.Writer, window: protocol.UsageWindow, now: u64) std.Io.Writer.Error!void {
    try out.writeAll(" · ");
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

fn fact(name: []const u8, label: []const u8, route: protocol.Route, usage: ?protocol.UsageReading) protocol.ConnectionFact {
    return .{ .name = connection.Name.parse(name).?, .label = @import("provider_route.zig").Label.parse(label).?, .route = route, .usage = usage };
}

test "SUI-182 the Connections reference names each window by its length and says when a connection shows no usage" {
    const now: u64 = 1_800_000_000;
    const week: protocol.UsageWindow = .{ .used_percent = 25.4, .minutes = 10080, .reset_at = now + 3 * 86400 + 4 * 3600 + 59 };
    const full: protocol.UsageWindow = .{ .used_percent = 100, .minutes = 300, .reset_at = now + 7 * 60 };
    const odd: protocol.UsageWindow = .{ .used_percent = 3, .minutes = 90, .reset_at = null };
    const facts = [_]protocol.ConnectionFact{
        fact("work", "ChatGPT (device code)", .chatgpt_device, .{ .observed_at = now - 12 * 60, .primary = week, .secondary = full }),
        fact("home", "ChatGPT", .chatgpt_plan, null),
        fact("lab", "ChatGPT (device code)", .chatgpt_device, null),
        fact("odd", "ChatGPT (device code)", .chatgpt_device, .{ .observed_at = now - 5, .primary = odd, .secondary = null }),
    };
    var rows: Rows = .{};
    const shown = build(&rows, &facts, now);
    try std.testing.expectEqual(@as(usize, 4), shown.len);
    try std.testing.expectEqualStrings("work", shown[0].label);
    try std.testing.expectEqualStrings("ChatGPT (device code) · weekly 25% used · resets in 3 d 4 h · 5-hour limit reached · resets in 7 m · as of 12 m ago", shown[0].value);
    try std.testing.expectEqualStrings("ChatGPT · usage not shown for browser sign-ins", shown[1].value);
    try std.testing.expectEqualStrings("ChatGPT (device code) · no usage seen yet", shown[2].value);
    try std.testing.expectEqualStrings("ChatGPT (device code) · 90-minute 3% used · as of just now", shown[3].value);
}
