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
    try std.testing.expectEqual(@as(usize, 12_501), index.len);
    try std.testing.expect(index.checkpoint_count <= 256);
    try std.testing.expect(index.stride > 1);
    const first_widget = (try index.builder().itemAtIdxForDraw(0, 0, ctx.arena)).?;
    const last = try (try index.builder().itemAtIdxForDraw(index.len - 1, 0, ctx.arena)).?.draw(ctx);
    // Seeking outside the window must not alter a widget already retained
    // by the same native frame.
    const first = try first_widget.draw(ctx);
    try std.testing.expectEqual(@as(u16, 1), first.size.height);
    try std.testing.expectEqual(@as(u16, 1), last.size.height);
    try std.testing.expectEqualStrings("x", first.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("界", last.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("!", last.readCell(2, 0).char.grapheme);
}

test "native wrapping advances across a grapheme wider than its viewport" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fw.DrawContext.init(.unicode);
    const narrow: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 1 }, .max = .{ .width = 1, .height = null }, .cell_size = .{} };
    const wide = narrow.withConstraints(.{ .width = 4 }, .{ .width = 4, .height = null });
    const original = "A界Z";
    const input = [_]fw.Text{.{ .text = original }};
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    try index.reflow(std.testing.allocator, &input, narrow);
    try std.testing.expectEqual(@as(usize, 3), index.len);
    try std.testing.expectEqualStrings("A", (try frameText(&index, 0, narrow.arena)).text);
    try std.testing.expectEqualStrings("界", (try frameText(&index, 1, narrow.arena)).text);
    try std.testing.expectEqualStrings("Z", (try frameText(&index, 2, narrow.arena)).text);
    const clipped = try (try index.builder().itemAtIdxForDraw(1, 0, narrow.arena)).?.draw(narrow);
    try std.testing.expectEqual(@as(u16, 1), clipped.size.height);
    try std.testing.expect(!std.mem.eql(u8, "界", clipped.readCell(0, 0).char.grapheme));
    try index.reflow(std.testing.allocator, &input, wide);
    try std.testing.expectEqual(@as(usize, 1), index.len);
    try std.testing.expectEqualStrings(original, (try frameText(&index, 0, wide.arena)).text);
    const restored = try (try index.builder().itemAtIdxForDraw(0, 0, wide.arena)).?.draw(wide);
    try std.testing.expectEqualStrings("界", restored.readCell(1, 0).char.grapheme);
    try std.testing.expectEqualStrings("Z", restored.readCell(3, 0).char.grapheme);
}

test "native text checkpoints preserve source boundaries and frame widgets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fw.DrawContext.init(.unicode);
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 16 }, .max = .{ .width = 16, .height = null }, .cell_size = .{} };
    const sources = try arena.allocator().alloc(fw.Text, 1_000);
    for (sources, 0..) |*source, i| {
        source.* = .{ .text = try std.fmt.allocPrint(arena.allocator(), "row-{d:0>4}", .{i}), .softwrap = i % 2 == 0 };
    }
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    try index.reflow(std.testing.allocator, sources, ctx);
    try std.testing.expectEqual(@as(usize, 1_000), index.len);
    try std.testing.expect(index.checkpoint_count <= 256);
    for ([_]usize{ 999, 0, 512, 127, 128, 255, 256, 998 }) |i| {
        const expected = try std.fmt.allocPrint(arena.allocator(), "row-{d:0>4}", .{i});
        try std.testing.expectEqualStrings(expected, (try frameText(&index, i, ctx.arena)).text);
    }
    const old = (try index.builder().itemAtIdxForDraw(0, 0, ctx.arena)).?;
    _ = try frameText(&index, 999, ctx.arena);
    const replacement = [_]fw.Text{.{ .text = "replacement" }};
    try index.reflow(std.testing.allocator, &replacement, ctx);
    const restored = try old.draw(ctx);
    try std.testing.expectEqualStrings("r", restored.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("0", restored.readCell(7, 0).char.grapheme);
}

fn frameText(index: *fw.Text.LineIndex, row: usize, arena: std.mem.Allocator) !*const fw.Text {
    const widget = (try index.builder().itemAtIdxForDraw(row, 0, arena)).?;
    return @ptrCast(@alignCast(widget.userdata));
}

const SeekFixture = struct {
    count: usize = 200_001,
    builds: usize = 0,
    tall_last: bool = false,

    fn has(raw: *const anyopaque, row: usize, _: usize) bool {
        const self: *const SeekFixture = @ptrCast(@alignCast(raw));
        return row < self.count;
    }

    fn build(raw: *const anyopaque, row: usize, _: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!?fw.Widget {
        const self: *SeekFixture = @ptrCast(@alignCast(@constCast(raw)));
        if (row >= self.count) return null;
        self.builds += 1;
        const text = try arena.create(fw.Text);
        text.* = .{ .text = if (self.tall_last and row == self.count - 1)
            "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nLAST"
        else
            try std.fmt.allocPrint(arena, "row-{d}", .{row}), .softwrap = false };
        return text.widget();
    }
};

test "native scroll end realizes only viewport across a far seek and tall last item" {
    fw.DrawContext.init(.unicode);
    for ([_]bool{ false, true }) |tall| {
        var storage: [512 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        var fixture: SeekFixture = .{ .tall_last = tall };
        var scroll: fw.ScrollView = .{
            .children = .{ .builder = .{ .userdata = &fixture, .hasFn = SeekFixture.has, .buildFrameFn = SeekFixture.build } },
            .item_count = @intCast(fixture.count),
        };
        const ctx: fw.DrawContext = .{ .arena = fixed.allocator(), .min = .{}, .max = .{ .width = 16, .height = 8 }, .cell_size = .{} };
        scroll.jumpToEnd();
        const surface = try scroll.draw(ctx);
        std.debug.print("far-seek tall={} builds={d} frame_bytes={d}\n", .{ tall, fixture.builds, fixed.end_index });
        try std.testing.expect(fixture.builds <= 10);
        try std.testing.expect(fixed.end_index < storage.len);
        const last = surface.children[surface.children.len - 1];
        try std.testing.expectEqual(@as(i17, 7), last.origin.row + @as(i17, last.surface.size.height) - 1);
        const end_row = last.surface.size.height - 1;
        try std.testing.expectEqualStrings(if (tall) "L" else "r", last.surface.readCell(0, end_row).char.grapheme);
    }
}

test "native scrollbar retains bottom thumb when horizontal row is reserved" {
    fw.DrawContext.init(.unicode);
    for ([_]u16{ 3, 9 }) |height| for ([_]bool{ false, true }) |tall| {
        var storage: [512 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        var fixture: SeekFixture = .{ .tall_last = tall };
        var bars: fw.ScrollBars = .{
            .scroll_view = .{
                .children = .{ .builder = .{ .userdata = &fixture, .hasFn = SeekFixture.has, .buildFrameFn = SeekFixture.build } },
                .item_count = @intCast(fixture.count),
            },
            .draw_horizontal_scrollbar = true,
        };
        const ctx: fw.DrawContext = .{ .arena = fixed.allocator(), .min = .{}, .max = .{ .width = 16, .height = height }, .cell_size = .{} };
        bars.scroll_view.jumpToEnd();
        const surface = try bars.draw(ctx);
        const vertical = surface.children[1].surface;
        try std.testing.expectEqual(height - 1, vertical.size.height);
        try std.testing.expectEqualStrings("▐", vertical.readCell(0, height - 2).char.grapheme);
    };
}

test "native horizontal line viewport reaches Unicode past one million columns" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    for (0..1_000_000) |_| try source.writer.writeByte('x');
    try source.writer.writeAll("界Z");
    var storage: [64 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    fw.DrawContext.init(.unicode);
    const ctx: fw.DrawContext = .{ .arena = fixed.allocator(), .min = .{ .width = 12 }, .max = .{ .width = 12, .height = null }, .cell_size = .{} };
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    const input = [_]fw.Text{.{ .text = source.written(), .softwrap = false }};
    try index.reflow(std.testing.allocator, &input, ctx);
    try std.testing.expectEqual(@as(usize, 1), index.len);
    const row = (try index.builder().itemAtIdxForDraw(0, 0, ctx.arena)).?;
    const surface = try row.drawHorizontalFn.?(row.userdata, ctx, 1_000_000, 12);
    try std.testing.expectEqual(@as(?u64, 1_000_003), surface.scroll_width);
    try std.testing.expectEqualStrings("界", surface.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("Z", surface.readCell(2, 0).char.grapheme);
    try std.testing.expect(fixed.end_index < storage.len);
}

test "native horizontal scrollbar drag stops at final complete viewport" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("HEAD");
    for (0..160) |_| try source.writer.writeByte('x');
    try source.writer.writeAll("界END");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fw.DrawContext.init(.unicode);
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 5 }, .cell_size = .{} };
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    const input = [_]fw.Text{.{ .text = source.written(), .softwrap = false }};
    try index.reflow(std.testing.allocator, &input, ctx);
    var bars: fw.ScrollBars = .{ .scroll_view = .{ .children = .{ .builder = index.builder() }, .item_count = 1 } };
    _ = try bars.draw(ctx);
    var event_ctx: fw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer event_ctx.cmds.deinit(std.testing.allocator);
    try bars.handleEvent(&event_ctx, .{ .mouse = .{ .col = 0, .row = 4, .button = .left, .mods = .{}, .type = .press } });
    try bars.handleCapture(&event_ctx, .{ .mouse = .{ .col = 19, .row = 4, .button = .left, .mods = .{}, .type = .drag } });
    const drawn = try bars.draw(ctx);
    const line = drawn.children[0].surface.children[0].surface;
    try std.testing.expectEqualStrings("界", line.readCell(14, 0).char.grapheme);
    try std.testing.expectEqualStrings("E", line.readCell(16, 0).char.grapheme);
    try std.testing.expectEqualStrings("D", line.readCell(18, 0).char.grapheme);

    const wide = ctx.withConstraints(.{}, .{ .width = 200, .height = 5 });
    const resized = try bars.draw(wide);
    const full = resized.children[0].surface.children[0].surface;
    try std.testing.expectEqualStrings("H", full.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("界", full.readCell(164, 0).char.grapheme);
    try std.testing.expectEqualStrings("D", full.readCell(168, 0).char.grapheme);
}

test "native horizontal viewport clips wide grapheme only at the edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fw.DrawContext.init(.unicode);
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 2 }, .max = .{ .width = 2, .height = null }, .cell_size = .{} };
    const original = "界X";
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    const input = [_]fw.Text{.{ .text = original, .softwrap = false }};
    try index.reflow(std.testing.allocator, &input, ctx);
    const row = (try index.builder().itemAtIdxForDraw(0, 0, ctx.arena)).?;
    const clipped = try row.drawHorizontalFn.?(row.userdata, ctx, 1, 2);
    try std.testing.expect(!std.mem.eql(u8, "界", clipped.readCell(0, 0).char.grapheme));
    try std.testing.expectEqualStrings("X", clipped.readCell(1, 0).char.grapheme);
    const restored = try row.drawHorizontalFn.?(row.userdata, ctx, 0, 2);
    try std.testing.expectEqualStrings("界", restored.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("界X", original);
}

test "native horizontal drag keeps wrapped labels and prose alongside code" {
    var source: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer source.deinit();
    try source.writer.writeAll("HEAD");
    for (0..160) |_| try source.writer.writeByte('x');
    try source.writer.writeAll("界END");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fw.DrawContext.init(.unicode);
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 20, .height = 7 }, .cell_size = .{} };
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    const input = [_]fw.Text{
        .{ .text = "Assistant\n" },
        .{ .text = "PROSE BEFORE\n" },
        .{ .text = source.written(), .softwrap = false },
        .{ .text = "PROSE AFTER" },
    };
    try index.reflow(std.testing.allocator, &input, ctx.withConstraints(.{ .width = 19 }, .{ .width = 19, .height = null }));
    var bars: fw.ScrollBars = .{ .scroll_view = .{ .children = .{ .builder = index.builder() }, .item_count = @intCast(index.len) } };
    _ = try bars.draw(ctx);
    var event_ctx: fw.EventContext = .{ .io = std.testing.io, .alloc = std.testing.allocator, .cmds = .empty };
    defer event_ctx.cmds.deinit(std.testing.allocator);
    try bars.handleEvent(&event_ctx, .{ .mouse = .{ .col = 0, .row = 6, .button = .left, .mods = .{}, .type = .press } });
    try bars.handleCapture(&event_ctx, .{ .mouse = .{ .col = 19, .row = 6, .button = .left, .mods = .{}, .type = .drag } });
    const frame = try bars.draw(ctx);
    const children = frame.children[0].surface.children;
    try std.testing.expectEqual(@as(usize, 4), children.len);
    try std.testing.expectEqual(@as(i17, 0), children[0].origin.col);
    try std.testing.expectEqualStrings("A", children[0].surface.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("P", children[1].surface.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("界", children[2].surface.readCell(14, 0).char.grapheme);
    try std.testing.expectEqualStrings("D", children[2].surface.readCell(18, 0).char.grapheme);
    try std.testing.expectEqual(@as(i17, 0), children[3].origin.col);
    try std.testing.expectEqualStrings("P", children[3].surface.readCell(0, 0).char.grapheme);
}

test "native horizontal text uses tab stops across viewport cuts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fw.DrawContext.init(.unicode);
    const ctx: fw.DrawContext = .{ .arena = arena.allocator(), .min = .{ .width = 4 }, .max = .{ .width = 4, .height = null }, .cell_size = .{} };
    const source = "ab\t界Z";
    try std.testing.expectEqual(@as(usize, 11), ctx.hardLineWidth(source));
    var index: fw.Text.LineIndex = .{};
    defer index.deinit(std.testing.allocator);
    const input = [_]fw.Text{.{ .text = source, .softwrap = false }};
    try index.reflow(std.testing.allocator, &input, ctx);
    const row = (try index.builder().itemAtIdxForDraw(0, 0, ctx.arena)).?;
    const first = try row.drawHorizontalFn.?(row.userdata, ctx, 0, 4);
    try std.testing.expectEqual(@as(?u64, 11), first.scroll_width);
    try std.testing.expectEqualStrings("a", first.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("b", first.readCell(1, 0).char.grapheme);
    try std.testing.expectEqualStrings(" ", first.readCell(2, 0).char.grapheme);
    const cut = try row.drawHorizontalFn.?(row.userdata, ctx, 7, 4);
    try std.testing.expectEqualStrings(" ", cut.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("界", cut.readCell(1, 0).char.grapheme);
    try std.testing.expectEqualStrings("Z", cut.readCell(3, 0).char.grapheme);
    const middle = try row.drawHorizontalFn.?(row.userdata, ctx, 9, 2);
    try std.testing.expect(!std.mem.eql(u8, "界", middle.readCell(0, 0).char.grapheme));
    try std.testing.expectEqualStrings("Z", middle.readCell(1, 0).char.grapheme);
}

test "native scroll extent reaches u32 ceiling with bounded viewport work" {
    const protocol = @import("protocol.zig");
    // An escaped byte can occupy four display columns. This only establishes
    // arithmetic representability, not that a particular Host stores this data.
    const two_max_expanded = protocol.max_sqlite_content_bytes * 4 * 2;
    try std.testing.expect(two_max_expanded > std.math.maxInt(u32));
    try std.testing.expectEqual(@as(?u32, null), std.math.cast(u32, two_max_expanded));
    try std.testing.expectEqual(u32, @FieldType(fw.ScrollView, "cursor"));

    fw.DrawContext.init(.unicode);
    var storage: [128 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var fixture: SeekFixture = .{ .count = std.math.maxInt(u32) };
    var scroll: fw.ScrollView = .{
        .children = .{ .builder = .{ .userdata = &fixture, .hasFn = SeekFixture.has, .buildFrameFn = SeekFixture.build } },
        .item_count = @intCast(fixture.count),
    };
    const ctx: fw.DrawContext = .{ .arena = fixed.allocator(), .min = .{}, .max = .{ .width = 20, .height = 8 }, .cell_size = .{} };
    scroll.jumpToEnd();
    const surface = try scroll.draw(ctx);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32) - 1), scroll.cursor);
    try std.testing.expect(fixture.builds <= 10);
    try std.testing.expect(fixed.end_index < storage.len);
    const last = surface.children[surface.children.len - 1];
    try std.testing.expectEqual(@as(i17, 7), last.origin.row + @as(i17, last.surface.size.height) - 1);
    try std.testing.expectEqualStrings("4", last.surface.readCell(13, 0).char.grapheme);
    std.debug.print("native ceiling count={d} beyond_u32={d} builds={d} frame_bytes={d}\n", .{ fixture.count, two_max_expanded, fixture.builds, fixed.end_index });
}

test "native frame watermark excludes queued input until successful flush" {
    const io = std.testing.io;
    var tty: vaxis.Tty = undefined;
    var vx: vaxis.Vaxis = undefined;
    var loop: vaxis.Loop(fw.Event) = .init(io, &tty, &vx);
    var ctx: fw.EventContext = .{ .io = io, .alloc = std.testing.allocator, .cmds = .empty };
    for (0..512) |_| try loop.postEvent(.{ .key_press = .{ .codepoint = 'x' } });
    const before = (try loop.tryStampedEvent()).?;
    try std.testing.expectEqual(@as(u64, 1), before.sequence);
    // Issued after layout started, before flush finishes: still old input.
    try loop.postEvent(.{ .key_press = .{ .codepoint = 'y' } });
    try std.testing.expectError(error.InjectedFlushFailure, fw.App.commitInputFrame(&ctx, &loop, error.InjectedFlushFailure));
    try std.testing.expectEqual(@as(u64, 0), ctx.frame_input_watermark);
    try fw.App.commitInputFrame(&ctx, &loop, {});
    try std.testing.expectEqual(@as(u64, 513), ctx.frame_input_watermark);
    for (0..512) |_| {
        const old = (try loop.tryStampedEvent()).?;
        try std.testing.expect(old.sequence <= ctx.frame_input_watermark);
    }
    try loop.postEvent(.{ .key_press = .{ .codepoint = 'z' } });
    const fresh = (try loop.tryStampedEvent()).?;
    try std.testing.expect(fresh.sequence > ctx.frame_input_watermark);
}
