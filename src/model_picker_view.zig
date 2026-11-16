const std = @import("std");
const model_catalog = @import("model_catalog.zig");
const gwidth = @import("terminal_width");
const picker = @import("model_picker.zig");
const overview = @import("overview_style.zig");

pub const Line = struct { text: []const u8, segments: []const overview.Segment };
pub const Read = enum { unread, read, unanswered, invalid };

const Columns = struct { context: bool = true };

pub fn modelLine(arena: std.mem.Allocator, entry: picker.Entry, row: picker.Row, id_width: usize, width: usize, unicode: bool) !Line {
    const buffer = try arena.alloc(u8, @max(entry.id.len, id_width) + 256);
    var columns: Columns = .{};
    if (cells(format(buffer, entry, row, id_width, columns, .unicode, unicode).text) > width) columns.context = false;
    const reserved = cells(format(buffer, entry, row, 0, columns, .unicode, unicode).text);
    const formatted = format(buffer, entry, row, @min(id_width, width -| reserved), columns, .unicode, unicode);
    const text = try arena.dupe(u8, formatted.text);
    return .{ .text = text, .segments = try segments(arena, text, formatted) };
}

fn cells(text: []const u8) usize {
    return gwidth.gwidth(text, .unicode);
}

const Range = struct { start: usize, end: usize, style: overview.Style };
const Formatted = struct { text: []const u8, ranges: [1]?Range = @splat(null) };

fn segments(arena: std.mem.Allocator, text: []const u8, formatted: Formatted) ![]const overview.Segment {
    const spans = try arena.alloc(overview.Segment, 3);
    var count: usize = 0;
    var offset: usize = 0;
    for (formatted.ranges) |maybe| if (maybe) |range| {
        if (offset < range.start) {
            spans[count] = .{ .text = text[offset..range.start], .style = .{} };
            count += 1;
        }
        spans[count] = .{ .text = text[range.start..range.end], .style = range.style };
        count += 1;
        offset = range.end;
    };
    if (offset < text.len) {
        spans[count] = .{ .text = text[offset..], .style = .{} };
        count += 1;
    }
    return spans[0..count];
}

fn format(buffer: []u8, entry: picker.Entry, row: picker.Row, id_width: usize, columns: Columns, method: gwidth.Method, unicode: bool) Formatted {
    var out: std.Io.Writer = .fixed(buffer);
    var ranges: [1]?Range = @splat(null);
    const mark = if (unicode) "✓" else "+";
    out.writeAll(if (row.current) mark else " ") catch unreachable;
    out.writeByte(' ') catch unreachable;
    if (row.current) ranges[0] = .{ .start = 0, .end = mark.len, .style = .{ .colour = .mark, .bold = true } };
    if (entry.id.len > id_width) {
        if (id_width > 0) {
            out.writeAll(entry.id[0 .. id_width - 1]) catch unreachable;
            out.writeAll(if (unicode) "…" else ".") catch unreachable;
        }
    } else {
        out.writeAll(entry.id) catch unreachable;
        for (entry.id.len..id_width) |_| out.writeByte(' ') catch unreachable;
    }
    if (columns.context) {
        const fact = if (entry.known) model_catalog.find(model_catalog.shipped, entry.id) else null;
        const window = if (fact) |known| known.context_window else null;
        const start = gwidth.gwidth(out.buffered(), method);
        if (window) |limit| {
            if (limit >= 1_000_000) {
                out.print("  {d}M", .{limit / 1_000_000}) catch unreachable;
            } else out.print("  {d}K", .{limit / 1_000}) catch unreachable;
        }
        while (gwidth.gwidth(out.buffered(), method) - start < 7) out.writeByte(' ') catch unreachable;
    }
    return .{ .text = out.buffered(), .ranges = ranges };
}

test "model picker view uses the Host's known flag for the displayed limit" {
    var menu = try picker.testMenu(&.{.{ .provider = .openai, .list = .{ .live = .{ .bytes = "gpt-6.1-sol\n" } } }});
    defer menu.deinit(std.testing.allocator);
    var entries = [_]picker.Entry{menu.entries[0]};
    entries[0].known = false;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const row = picker.Query.parse("").row(entries[0], .{}).?;
    const shown = try modelLine(arena.allocator(), entries[0], row, entries[0].id.len, 100, true);
    const text = shown.text;
    try std.testing.expect(std.mem.indexOf(u8, text, "1M") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "K") == null);
}

test "model picker shared ASCII model rows preserve compact mark gap and truncation" {
    const entry: picker.Entry = .{ .id = "gpt-6.1-sol", .known = true, .catalogued = true, .providers = .initOne(.codex) };
    const row = picker.Query.parse("").row(entry, .{ .model = entry.id, .provider = .codex }).?;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for (0..100) |width| {
        const line = try modelLine(arena.allocator(), entry, row, entry.id.len, width, false);
        for (line.text) |byte| try std.testing.expect(byte < 0x80);
        try std.testing.expect(std.mem.startsWith(u8, line.text, "+ "));
    }
    const unicode = try modelLine(arena.allocator(), entry, row, entry.id.len, 99, true);
    try std.testing.expect(std.mem.startsWith(u8, unicode.text, "✓ gpt-6.1-sol"));
    const ascii = try modelLine(arena.allocator(), entry, row, entry.id.len, 99, false);
    try std.testing.expect(std.mem.startsWith(u8, ascii.text, "+ gpt-6.1-sol"));
}
