//! Versioned byte spans in a Bash result. Counts describe stored UTF-8, not captures.
const std = @import("std");
pub const prefix = "RUI-BASH-RESULT/1 ";
pub const max_header = 128;
pub const Kind = enum { plain, bash };
/// Preamble, stdout, separator, stderr and footer, in stored byte order.
/// Stream spans contain encoded output only; prose belongs to other spans.
pub const Spans = [5]u64;
pub fn header(buffer: []u8, spans: Spans) ![]const u8 {
    return std.fmt.bufPrint(buffer, prefix ++ "{d} {d} {d} {d} {d}\n", .{ spans[0], spans[1], spans[2], spans[3], spans[4] });
}
pub fn decode(line: []const u8) ?Spans {
    if (!std.mem.startsWith(u8, line, prefix) or !std.mem.endsWith(u8, line, "\n")) return null;
    var parts = std.mem.splitScalar(u8, line[prefix.len .. line.len - 1], ' ');
    var spans: Spans = undefined;
    for (&spans) |*span| {
        const digits = parts.next() orelse return null;
        if (digits.len == 0) return null;
        for (digits) |digit| if (!std.ascii.isDigit(digit)) return null;
        span.* = std.fmt.parseInt(u64, digits, 10) catch return null;
    }
    if (parts.next() != null) return null;
    return spans;
}
pub fn parse(line: []const u8, total: u64) ?Spans {
    const spans = decode(line) orelse return null;
    var sum: u64 = line.len;
    for (spans) |span| sum = std.math.add(u64, sum, span) catch return null;
    return if (sum == total) spans else null;
}
test "framing binds all five spans and exact total" {
    var buffer: [max_header]u8 = undefined;
    const spans: Spans = .{ 12, 3, 5, 0, 9 };
    const bytes = try header(&buffer, spans);
    try std.testing.expectEqual(spans, parse(bytes, bytes.len + 29).?);
    try std.testing.expect(parse(bytes, bytes.len + 30) == null);
    try std.testing.expect(parse("RUI-BASH-RESULT/1 0 0 0 0 18446744073709551615\n", 1) == null);
}
