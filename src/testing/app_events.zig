//! The bytes a terminal sends, delivered to a screen as App delivers them:
//! vaxis's own Parser decodes them, Root's capture sees each event first,
//! and the focused screen gets what Root leaves unconsumed.
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

/// Delivers each complete event in `bytes`, in order, through `root`'s
/// capture and then to `focused`. A malformed sequence ends the batch, as
/// App's loop discards one; an incomplete tail is dropped.
pub fn send(ctx: *vxfw.EventContext, bytes: []const u8, root: vxfw.Widget, focused: vxfw.Widget) !void {
    var parser: vaxis.Parser = .{};
    var at: usize = 0;
    while (at < bytes.len and !ctx.quit) {
        const result = parser.parse(bytes[at..], null) catch return;
        if (result.n == 0) return;
        at += result.n;
        const event: vxfw.Event = switch (result.event orelse continue) {
            .key_press => |key| .{ .key_press = key },
            .key_release => |key| .{ .key_release = key },
            .paste_start => .paste_start,
            .paste_end => .paste_end,
            .invalid_key => .invalid_key,
            .focus_in => .focus_in,
            .focus_out => .focus_out,
            else => continue,
        };
        ctx.consume_event = false;
        ctx.phase = .capturing;
        try root.captureEvent(ctx, event);
        if (ctx.consume_event) continue;
        ctx.phase = .at_target;
        try focused.handleEvent(ctx, event);
    }
}
