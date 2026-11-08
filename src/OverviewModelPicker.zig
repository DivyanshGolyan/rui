//! The overview shell's native model-list cursor and viewport.
//! The functional core sees only a borrowed model identity and returns move
//! intents; this owner never duplicates the library's cursor or scroll.
const std = @import("std");
const vaxis = @import("vaxis");
const view = @import("overview_view.zig");
const model_capability = @import("model_capability.zig");

const Self = @This();
list: vaxis.vxfw.ListView = .{ .children = .{ .slice = &.{} }, .item_count = 0, .draw_cursor = false },

/// The ID borrows the menu until its next replacement.
pub fn selected(self: *const Self, state: *const view.State) ?[]const u8 {
    if (state.picker == null or self.list.cursor >= state.menu.entries.len) return null;
    return state.shownMenu().entry(self.list.cursor).id;
}

/// Applies one core event, then consumes only its native model-list movement.
/// A copied ID bridges a menu replacement without a second retained cursor.
pub fn step(self: *Self, state: *view.State, event: view.Event) error{OutOfMemory}!view.Effects {
    var id: [model_capability.max_model_bytes]u8 = undefined;
    const selected_id = if (self.selected(state)) |selected| blk: {
        @memcpy(id[0..selected.len], selected);
        break :blk id[0..selected.len];
    } else null;
    var effects = try view.stepSelected(state, event, selected_id);
    if (state.picker == null) {
        self.list = .{ .children = .{ .slice = &.{} }, .item_count = 0, .draw_cursor = false };
    } else {
        self.list.item_count = @intCast(state.menu.entries.len);
        const at = if (selected_id) |selected| state.menu.find(selected) else null;
        const row: usize = if (at) |index| state.shownMenu().row(index) else 0;
        if (self.list.cursor != row or at == null) self.list.jumpToItem(@intCast(row));
    }
    var kept: usize = 0;
    for (effects.slice()) |effect| switch (effect) {
        .model_move => |movement| {
            var context: vaxis.vxfw.EventContext = .{ .io = undefined, .alloc = state.gpa, .cmds = .empty };
            switch (movement) {
                .first => self.list.jumpToItem(0),
                .last => if (state.menu.entries.len != 0) self.list.jumpToItem(@intCast(state.menu.entries.len - 1)),
                .next => self.list.nextItem(&context),
                .previous => self.list.prevItem(&context),
            }
        },
        else => {
            effects.items[kept] = effect;
            kept += 1;
        },
    };
    effects.len = kept;
    return effects;
}
