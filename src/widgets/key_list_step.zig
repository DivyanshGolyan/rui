//! The selection and scroll policy of a KeyList, as plain values: a shape and a position with an event give the next position.
//! The widget translates key and mouse events into these events, stores the position it gets back, and draws it. A block taller
//! than the viewport scrolls within itself before the selection moves on, so each of its rows comes into view.
const std = @import("std");

/// Consecutive rows the user selects as one.
pub const Block = struct { first: usize, end: usize };

/// What the list holds: its blocks (none for a plain list of rows), its rows and the rows on screen.
pub const Shape = struct {
    blocks: []const Block,
    total_rows: usize,
    viewport_height: usize,
};

/// Where the list is: the selected block (zero for a plain list) and the first row on screen.
pub const Position = struct {
    selected: usize = 0,
    row_offset: usize = 0,
};

pub const Event = union(enum) {
    /// One block up or down, or one row of a plain list.
    step: isize,
    /// About one screenful of blocks, or one viewport of rows.
    page: isize,
    /// A left press on the block with this index.
    press: usize,
};

/// The position `at` must stand in for `shape`: the selection on a block that exists, the scroll within the rows that exist.
pub fn settle(shape: Shape, at: Position) Position {
    if (shape.blocks.len == 0) return .{ .selected = 0, .row_offset = clampOffset(shape, at.row_offset) };
    const selected = @min(at.selected, shape.blocks.len - 1);
    return moveTo(shape, .{ .selected = selected, .row_offset = clampOffset(shape, at.row_offset) }, selected, false);
}

/// The position after `event` from `at`. The position is settled first, so a stale position moves from where it stands.
pub fn next(shape: Shape, at: Position, event: Event) Position {
    const settled = settle(shape, at);
    if (shape.blocks.len == 0) return switch (event) {
        .step => |delta| scrollRows(shape, settled, delta),
        .page => |direction| scrollRows(shape, settled, direction * height(shape)),
        .press => settled,
    };
    return switch (event) {
        .step => |delta| stepBlock(shape, settled, delta),
        .page => |direction| moveBlocks(shape, settled, direction * perPage(shape, settled)),
        .press => |index| settle(shape, .{ .selected = index, .row_offset = settled.row_offset }),
    };
}

fn height(shape: Shape) isize {
    return @intCast(shape.viewport_height);
}

/// The largest first row on screen: the rows that do not fit beside the last screenful.
fn most(shape: Shape) usize {
    return shape.total_rows -| shape.viewport_height;
}

fn clampOffset(shape: Shape, offset: usize) usize {
    return @min(offset, most(shape));
}

fn oversized(shape: Shape, block: Block) bool {
    return block.end - block.first > shape.viewport_height;
}

/// Whether any row of `block` is on screen from `offset`.
fn overlaps(shape: Shape, block: Block, offset: usize) bool {
    return offset < block.end and offset + shape.viewport_height > block.first;
}

/// The first row on screen once `block` is selected from `offset`. A block taller than the viewport keeps the rows on screen while
/// they overlap it, else it comes in at its top, or at its bottom when moving up (`from_below`). A shorter block comes fully into view.
fn reveal(shape: Shape, block: Block, offset: usize, from_below: bool) usize {
    if (oversized(shape, block)) {
        if (overlaps(shape, block, offset)) return offset;
        return if (from_below) block.end -| shape.viewport_height else block.first;
    }
    if (block.first < offset) return block.first;
    if (block.end > offset + shape.viewport_height) return block.end - shape.viewport_height;
    return offset;
}

fn moveTo(shape: Shape, at: Position, target: usize, from_below: bool) Position {
    const offset = reveal(shape, shape.blocks[target], at.row_offset, from_below);
    return .{ .selected = target, .row_offset = clampOffset(shape, offset) };
}

/// A block list's step: a block taller than the viewport scrolls one row toward the part not yet shown, and only then does the
/// selection move to the next or previous block.
fn stepBlock(shape: Shape, at: Position, delta: isize) Position {
    const block = shape.blocks[at.selected];
    if (delta > 0 and oversized(shape, block) and block.end > at.row_offset + shape.viewport_height) {
        return .{ .selected = at.selected, .row_offset = clampOffset(shape, at.row_offset + 1) };
    }
    if (delta < 0 and oversized(shape, block) and block.first < at.row_offset) {
        return .{ .selected = at.selected, .row_offset = at.row_offset - 1 };
    }
    return moveBlocks(shape, at, delta);
}

/// Moves the selection `delta` blocks, saturating at the first and last, and reveals the block it lands on.
fn moveBlocks(shape: Shape, at: Position, delta: isize) Position {
    const last: isize = @intCast(shape.blocks.len - 1);
    const target: usize = @intCast(std.math.clamp(@as(isize, @intCast(at.selected)) + delta, 0, last));
    return moveTo(shape, at, target, delta < 0);
}

/// Blocks per page: the viewport over the selected block's height, at least one.
fn perPage(shape: Shape, at: Position) isize {
    const block = shape.blocks[at.selected];
    return @intCast(@max(1, shape.viewport_height / @max(1, block.end - block.first)));
}

/// A plain list's scroll by `delta` rows, kept within the rows that exist.
fn scrollRows(shape: Shape, at: Position, delta: isize) Position {
    const moved = std.math.clamp(@as(isize, @intCast(at.row_offset)) + delta, 0, @as(isize, @intCast(most(shape))));
    return .{ .selected = 0, .row_offset = @intCast(moved) };
}

/// Fields for `count` blocks of `block_height` rows, one blank row between each pair; returns the row count.
fn stack(blocks: []Block, count: usize, block_height: usize) usize {
    var rows: usize = 0;
    for (blocks[0..count], 0..) |*block, index| {
        if (index > 0) rows += 1;
        block.* = .{ .first = rows, .end = rows + block_height };
        rows += block_height;
    }
    return rows;
}

/// The block heights the domain tests cover, against a viewport of `viewport` rows.
const Layout = enum { shorter, equal, taller };

fn blockHeight(layout: Layout, viewport: usize) usize {
    return switch (layout) {
        .shorter => @max(1, viewport -| 1),
        .equal => viewport,
        .taller => viewport + 2,
    };
}

fn expectInDomain(shape: Shape, at: Position) !void {
    try std.testing.expect(at.row_offset <= most(shape));
    if (shape.blocks.len == 0) return std.testing.expectEqual(@as(usize, 0), at.selected);
    try std.testing.expect(at.selected < shape.blocks.len);
    const block = shape.blocks[at.selected];
    if (oversized(shape, block)) return std.testing.expect(overlaps(shape, block, at.row_offset));
    try std.testing.expect(block.first >= at.row_offset);
    try std.testing.expect(block.end <= at.row_offset + shape.viewport_height);
}

/// Marks the rows on screen at `at`.
fn markRows(shape: Shape, at: Position, seen: []bool) void {
    const bottom = @min(shape.total_rows, at.row_offset + shape.viewport_height);
    for (at.row_offset..bottom) |row| seen[row] = true;
}

/// Steps `delta` until the position stops moving, marking every row shown on the way; returns the final position.
fn walk(shape: Shape, from: Position, delta: isize, seen: []bool) !Position {
    var at = settle(shape, from);
    markRows(shape, at, seen);
    for (0..1000) |_| {
        const moved = next(shape, at, .{ .step = delta });
        if (std.meta.eql(moved, at)) return at;
        at = moved;
        markRows(shape, at, seen);
    }
    return error.DidNotSettle;
}

test "SUI-202 a selected block stays in range and in view through every step, page and press, for blocks shorter than, equal to and taller than the viewport" {
    var blocks: [3]Block = undefined;
    for (1..7) |viewport| for ([_]Layout{ .shorter, .equal, .taller }) |layout| for (1..4) |count| {
        const rows = stack(&blocks, count, blockHeight(layout, viewport));
        const shape: Shape = .{ .blocks = blocks[0..count], .total_rows = rows, .viewport_height = viewport };
        for (0..count) |selected| for (0..rows + 3) |row_offset| {
            const at: Position = .{ .selected = selected, .row_offset = row_offset };
            for ([_]Event{ .{ .step = 1 }, .{ .step = -1 }, .{ .page = 1 }, .{ .page = -1 } }) |event| {
                try expectInDomain(shape, next(shape, at, event));
            }
            for (0..count) |index| try expectInDomain(shape, next(shape, at, .{ .press = index }));
        };
    };
}

test "SUI-203 every row of every block comes into view stepping down, and again stepping back up, for blocks shorter than, equal to and taller than the viewport" {
    var blocks: [3]Block = undefined;
    for (1..7) |viewport| for ([_]Layout{ .shorter, .equal, .taller }) |layout| for (1..4) |count| {
        const rows = stack(&blocks, count, blockHeight(layout, viewport));
        const shape: Shape = .{ .blocks = blocks[0..count], .total_rows = rows, .viewport_height = viewport };
        var seen: [32]bool = @splat(false);
        const bottom = try walk(shape, .{}, 1, &seen);
        try std.testing.expectEqual(count - 1, bottom.selected);
        for (blocks[0..count]) |block| for (block.first..block.end) |row| try std.testing.expect(seen[row]);
        seen = @splat(false);
        const top = try walk(shape, bottom, -1, &seen);
        try std.testing.expectEqual(@as(usize, 0), top.selected);
        for (blocks[0..count]) |block| for (block.first..block.end) |row| try std.testing.expect(seen[row]);
    };
}

test "SUI-204 a plain list scrolls one row at a time and one screenful a page, kept within its rows" {
    for (1..7) |viewport| for (0..11) |rows| {
        const shape: Shape = .{ .blocks = &.{}, .total_rows = rows, .viewport_height = viewport };
        var seen: [32]bool = @splat(false);
        const bottom = try walk(shape, .{}, 1, &seen);
        try std.testing.expectEqual(rows -| viewport, bottom.row_offset);
        try std.testing.expectEqual(@as(usize, 0), bottom.selected);
        const top = try walk(shape, bottom, -1, &seen);
        try std.testing.expectEqual(@as(usize, 0), top.row_offset);
        const paged = next(shape, .{}, .{ .page = 1 });
        try std.testing.expectEqual(@min(viewport, rows -| viewport), paged.row_offset);
        try std.testing.expectEqual(@as(usize, 0), next(shape, .{}, .{ .page = -1 }).row_offset);
    };
}

test "SUI-205 settling is idempotent over the domain, and a press selects the pressed block in view" {
    var blocks: [3]Block = undefined;
    for (1..7) |viewport| for ([_]Layout{ .shorter, .equal, .taller }) |layout| for (1..4) |count| {
        const rows = stack(&blocks, count, blockHeight(layout, viewport));
        const shape: Shape = .{ .blocks = blocks[0..count], .total_rows = rows, .viewport_height = viewport };
        for (0..count + 2) |selected| for (0..rows + 3) |row_offset| {
            const once = settle(shape, .{ .selected = selected, .row_offset = row_offset });
            try expectInDomain(shape, once);
            try std.testing.expectEqual(once, settle(shape, once));
        };
        for (0..count) |index| {
            const pressed = next(shape, .{}, .{ .press = index });
            try std.testing.expectEqual(index, pressed.selected);
            try expectInDomain(shape, pressed);
        }
    };
}
