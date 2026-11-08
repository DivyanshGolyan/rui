const std = @import("std");
const vaxis = @import("vaxis");
const fw = vaxis.vxfw;

test "native multiline composer keeps text, cursor and non-destructive submit snapshot" {
    var field = fw.TextField.init(std.testing.allocator);
    defer field.deinit();
    field.multiline = true;
    try field.insertSliceAtCursor("one\n界x");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fw.DrawContext.init(.unicode);
    const draw: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 10, .height = 5 }, .cell_size = .{} };
    const surface = try field.draw(draw);
    try std.testing.expectEqual(@as(u16, 2), surface.size.height);
    try std.testing.expectEqualStrings("界", surface.readCell(0, 1).char.grapheme);
    var ctx: fw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer ctx.cmds.deinit(std.testing.allocator);
    try field.handleEvent(&ctx, .{ .key_press = .{ .codepoint = vaxis.Key.up } });
    try std.testing.expectEqual(@as(usize, 3), field.byteOffsetToCursor());
    const frozen = try field.snapshot();
    defer std.testing.allocator.free(frozen);
    try field.insertSliceAtCursor("!");
    try std.testing.expectEqualStrings("one\n界x", frozen);
    const now = try field.snapshot();
    defer std.testing.allocator.free(now);
    try std.testing.expectEqualStrings("one!\n界x", now);
}

test "native text keeps the end of a long unbroken Unicode line" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for (0..10_000) |_| try source.writer.writeByte('x');
    try source.writer.writeAll("界!");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fw.DrawContext.init(.unicode);
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 80 }, .max = .{ .width = 80, .height = null }, .cell_size = .{} };
    const text: fw.Text = .{ .text = source.written(), .softwrap = true, .width_basis = .parent };
    const surface = try text.draw(ctx);
    try std.testing.expectEqual(@as(u16, 126), surface.size.height);
    try std.testing.expectEqualStrings("x", surface.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("界", surface.readCell(0, 125).char.grapheme);
    try std.testing.expectEqualStrings("!", surface.readCell(2, 125).char.grapheme);
}

test "native text extent indexes long output without full-height cell surfaces" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for (0..1_000_000) |_| try source.writer.writeByte('x');
    try source.writer.writeAll("界!");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fw.DrawContext.init(.unicode);
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 80 }, .max = .{ .width = 80, .height = null }, .cell_size = .{} };
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    const inputs = [_]fw.Text{.{ .text = source.written() }};
    try index.reflow(std.testing.allocator, &inputs, ctx);
    try std.testing.expectEqual(@as(usize, 12_501), index.lines.items.len);
    const first = try index.builder().itemAtIdx(0, 0).?.draw(ctx);
    const last = try index.builder().itemAtIdx(index.lines.items.len - 1, 0).?.draw(ctx);
    try std.testing.expectEqual(@as(u16, 1), first.size.height);
    try std.testing.expectEqual(@as(u16, 1), last.size.height);
    try std.testing.expectEqualStrings("x", first.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("界", last.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("!", last.readCell(2, 0).char.grapheme);
}
