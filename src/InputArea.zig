//! Composer and the two independent rows beneath it, shared by both screens.
//! Screens supply terminal-safe facts and status text; notices never take the
//! facts row. The floating palette belongs to the content above this area.
const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;
const Composer = @import("Composer.zig");
const PermissionCard = @import("PermissionCard.zig");
const Self = @This();
const empty: vxfw.Text = .{ .text = "" };
/// The status's most lines: a command's short result.
const status_lines = @import("slash_commands.zig").short_result_lines;

composer: Composer,
permission: ?*PermissionCard = null,
facts: vxfw.Widget = empty.widget(),
status: vxfw.Widget = empty.widget(),

pub fn widget(self: *Self) vxfw.Widget {
    return .{ .userdata = self, .drawFn = draw };
}

fn draw(raw: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Self = @ptrCast(@alignCast(raw));
    const size = ctx.max.size();
    if (size.width == 0 or size.height == 0) return vxfw.Surface.init(ctx.arena, self.widget(), .{});
    // The facts row, then the status: a line, or as many as a command's
    // short result has, while the content keeps a row.
    const facts_rows: u16 = @min(1, size.height - 1);
    const status_room: u16 = @min(status_lines, size.height -| 1 -| facts_rows);
    const status = if (status_room == 0) null else try self.status.draw(ctx.withConstraints(.{ .width = size.width, .height = 1 }, .{ .width = size.width, .height = status_room }));
    const footer_rows = facts_rows + if (status) |drawn| @min(drawn.size.height, status_room) else 0;
    const children = try ctx.arena.alloc(vxfw.SubSurface, 1 + facts_rows + @intFromBool(status != null));
    const primary = if (self.permission) |card| card.widget() else self.composer.widget();
    const content = try primary.draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height - footer_rows }));
    const row = ctx.withConstraints(.{ .width = size.width, .height = 1 }, .{ .width = size.width, .height = 1 });
    children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = content };
    if (facts_rows == 1) children[1] = .{ .origin = .{ .row = content.size.height, .col = 0 }, .surface = try self.facts.draw(row) };
    if (status) |drawn| children[1 + facts_rows] = .{ .origin = .{ .row = content.size.height + facts_rows, .col = 0 }, .surface = drawn };
    return .{ .widget = self.widget(), .size = .{ .width = size.width, .height = content.size.height + footer_rows }, .buffer = &.{}, .children = children };
}

test "InputArea keeps facts below the composer when a notice replaces the status" {
    var bytes: [128]u8 = undefined;
    var editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes };
    const facts: vxfw.RichText = .{ .text = &.{.{ .text = "new Session · gpt-6.1-sol · high · ~/rui" }}, .softwrap = false, .width_basis = .parent };
    var status: vxfw.RichText = .{ .text = &.{.{ .text = "enter sends" }}, .softwrap = false, .width_basis = .parent };
    var input: Self = .{
        .composer = .{ .editor = &editor, .placeholder = "Type a task" },
        .facts = facts.widget(),
        .status = status.widget(),
    };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    for ([_]vxfw.Size{ .{ .width = 80, .height = 24 }, .{ .width = 40, .height = 10 } }) |size| {
        const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = size.width, .height = size.height }, .cell_size = .{} };
        status.text = &.{.{ .text = "enter sends" }};
        const idle = try input.widget().draw(ctx);
        try std.testing.expectEqual(@as(u16, 5), idle.size.height);
        try std.testing.expectEqual(@as(i17, 3), idle.children[1].origin.row);
        try std.testing.expectEqual(@as(i17, 4), idle.children[2].origin.row);
        try std.testing.expectEqualStrings("n", idle.children[1].surface.readCell(0, 0).char.grapheme);
        try std.testing.expectEqualStrings("e", idle.children[2].surface.readCell(0, 0).char.grapheme);
        // A command's two-line result takes two rows; the composer moves up.
        status.text = &.{.{ .text = "Configured.\n! label saved locally only" }};
        const two = try input.widget().draw(ctx);
        try std.testing.expectEqual(@as(u16, 6), two.size.height);
        try std.testing.expectEqual(@as(u16, 2), two.children[2].surface.size.height);
        try std.testing.expectEqualStrings("!", two.children[2].surface.readCell(0, 1).char.grapheme);
        status.text = &.{.{ .text = "Not sent: this Action needs a decision", .style = .{ .bold = true } }};
        const notice = try input.widget().draw(ctx);
        try std.testing.expectEqualDeep(idle.children[1].surface.buffer, notice.children[1].surface.buffer);
        try std.testing.expectEqualStrings("N", notice.children[2].surface.readCell(0, 0).char.grapheme);
        try std.testing.expect(notice.children[2].surface.readCell(0, 0).style.bold);
    }
    const draft = "one\ntwo\nthree\nfour\nfive\nsix";
    @memcpy(bytes[0..draft.len], draft);
    editor.length = draft.len;
    editor.cursor = draft.len;
    const small = try input.widget().draw(.{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 5 }, .cell_size = .{} });
    try std.testing.expectEqual(@as(u16, 5), small.size.height);
    try std.testing.expectEqualStrings("s", small.children[0].surface.readCell(2, 1).char.grapheme);
    try std.testing.expectEqualStrings("n", small.children[1].surface.readCell(0, 0).char.grapheme);
    try std.testing.expectEqualStrings("N", small.children[2].surface.readCell(0, 0).char.grapheme);
}

test "InputArea survives one-cell and empty resizes without changing the draft or caret" {
    var bytes = "left\nrightTAIL".*;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes, .length = bytes.len, .cursor = 10 };
    var input: Self = .{ .composer = .{ .editor = &editor } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 80, .height = 24 }, .cell_size = .{} };
    const before = try input.widget().draw(ctx);
    for ([_]vxfw.Size{ .{ .width = 1, .height = 1 }, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 0 }, .{ .width = 2, .height = 2 }, .{ .width = 3, .height = 4 } }) |size| {
        const surface = try input.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        try std.testing.expect(surface.size.width <= size.width and surface.size.height <= size.height);
        if (size.width == 0 or size.height == 0) {
            try std.testing.expectEqual(@as(usize, 0), surface.children.len);
        } else {
            const composer = surface.children[0].surface;
            try std.testing.expect(composer.cursor.?.col < composer.size.width);
            try std.testing.expect(composer.cursor.?.row < composer.size.height);
        }
        try std.testing.expectEqualStrings("left\nrightTAIL", editor.buffer[0..editor.length]);
        try std.testing.expectEqual(@as(usize, 10), editor.cursor);
    }
    const restored = try input.widget().draw(ctx);
    try std.testing.expectEqualDeep(before.children[0].surface.buffer, restored.children[0].surface.buffer);
    try std.testing.expectEqualDeep(before.children[0].surface.cursor, restored.children[0].surface.cursor);
}

test "InputArea permission hides and restores the draft and its caret after deciding" {
    const Consent = @import("ActionConsent.zig");
    const Owner = struct {
        decision: ?@import("session_consent.zig").Decision = null,
        fn decide(raw: *anyopaque, _: *vxfw.EventContext, decision: @import("session_consent.zig").Decision) !void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.decision = decision;
        }
    };
    var owner: Owner = .{};
    var bytes = "only the retry tests".*;
    const editor: @import("TerminalEditor.zig") = .{ .buffer = &bytes, .length = bytes.len, .cursor = 9 };
    var consent: Consent = .{};
    const command: vxfw.Text = .{ .text = "$ zig build test-store" };
    const pasting = false;
    var card: PermissionCard = .{ .consent = &consent, .pasting = &pasting, .description = "Run tests", .body = command.widget(), .userdata = &owner, .on_decision = Owner.decide };
    var input: Self = .{ .composer = .{ .editor = &editor } };
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const ctx: vxfw.DrawContext = .{ .arena = arena.allocator(), .min = .{}, .max = .{ .width = 40, .height = 7 }, .cell_size = .{} };
    const before = try input.widget().draw(ctx);
    consent.adopt(37);
    input.permission = &card;
    var events: vxfw.EventContext = .{ .io = std.testing.io, .alloc = arena.allocator(), .cmds = .empty };
    for ([_]vxfw.Size{ .{ .width = 40, .height = 7 }, .{ .width = 1, .height = 1 }, .{ .width = 40, .height = 7 } }) |size| {
        const shown = try input.widget().draw(ctx.withConstraints(.{}, .{ .width = size.width, .height = size.height }));
        try std.testing.expect(shown.children[0].surface.widget.eql(card.widget()));
        try std.testing.expectEqual(null, shown.children[0].surface.cursor);
        try card.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = 'x' } });
        try std.testing.expectEqualStrings("only the retry tests", editor.buffer[0..editor.length]);
        try std.testing.expectEqual(@as(usize, 9), editor.cursor);
    }
    try card.widget().handleEvent(&events, .{ .key_press = .{ .codepoint = vaxis.Key.enter } });
    try std.testing.expectEqual(@as(u64, 37), owner.decision.?.action);
    input.permission = null;
    const after = try input.widget().draw(ctx);
    try std.testing.expectEqualDeep(before.children[0].surface.buffer, after.children[0].surface.buffer);
    try std.testing.expectEqualDeep(before.children[0].surface.cursor, after.children[0].surface.cursor);
}
