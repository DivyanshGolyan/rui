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
