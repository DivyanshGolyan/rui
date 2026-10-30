//! Native adapter actor: no Host, frontend or syscall interposition.
const std = @import("std");
const Terminal = @import("SessionTerminal.zig");
const Input = @import("TerminalInput.zig");
const Editor = @import("TerminalEditor.zig");
const keymap = @import("keymap.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "input-replay")) {
        // begin/next/finish do not draw through screen. Use the production
        // terminal owner, decoder and editor, without a frontend or Store.
        var terminal = try Terminal.begin(undefined);
        const result = replay(init.io, &terminal);
        // Match session_departure: unconfirmed terminal restoration outranks
        // an input error. Generic process-disposal precedence does not apply.
        try terminal.finish();
        return result;
    }
    if (args.len != 1) return error.InvalidArguments;
    const flags = std.c.fcntl(1, std.c.F.GETFL);
    if (flags < 0) return error.TerminalCleanupFailed;
    var terminal: Terminal = .{
        .original = undefined,
        .flags = .{ 0, flags },
        .screen = undefined,
        .active = false,
    };
    try terminal.detached("/tmp/a' path", "k7m2qx", null);
}

fn replay(io: std.Io, terminal: *Terminal) !void {
    var storage: [128]u8 = undefined;
    @memcpy(storage[0..8], "headTAIL");
    var editor: Editor = .{ .buffer = &storage, .length = 8, .cursor = 4 };
    var input: Input = .{};
    std.debug.print("ready\n", .{});
    while (true) {
        const read = terminal.next(io, &input, 10) catch |err| switch (err) {
            error.InputDeadline => {
                if (try input.expire() != .none) std.debug.print("expired escape\n", .{});
                continue;
            },
            else => return err,
        } orelse continue;
        var decoded = input.feed(read.byte, read.at);
        while (decoded != .none) : (decoded = input.next()) {
            // Each key the editor has no use for is named as itself.
            const outcome = editor.apply(keymap.every, decoded);
            // This bounded private transcript exposes decoded events as well
            // as editor outcomes. Expectations live in Python, not this actor.
            const kind: []const u8, const point: u21, const mods: u8, const pasted: bool = switch (decoded) {
                .event => |value| switch (value.event) {
                    .key_press => |key| .{ "key_press", key.codepoint, @bitCast(key.mods), value.pasted },
                    .key_release => |key| .{ "key_release", key.codepoint, @bitCast(key.mods), value.pasted },
                    else => .{ @tagName(value.event), 0, 0, value.pasted },
                },
                else => .{ @tagName(decoded), 0, 0, input.paste },
            };
            const name = switch (outcome) {
                .action => |key| @tagName(key),
                else => @tagName(outcome),
            };
            std.debug.print("event {s} {d} {d} {} {s} {x} {d}\n", .{
                kind, point, mods, pasted, name, storage[0..editor.length], editor.cursor,
            });
            // Enter ends the line; Ctrl-C ends the replay, as it ends a prompt.
            if (outcome.endsLine() or (outcome == .action and outcome.action == .ctrl_c)) return;
        }
    }
}
