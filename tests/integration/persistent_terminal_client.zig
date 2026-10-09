const std = @import("std");
const Editor = @import("terminal_editor");

// Native adapter for PTY drivers. Uses the actual persistent terminal owner;
// no alternate parser, read-ahead, cleanup policy or display implementation.
// Ctrl-R/G write notices while retaining bytes/cursor. Enter accepts one line
// only after confirmed final cleanup; Ctrl-C fails and empty Ctrl-D detaches.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var terminal = try Editor.Terminal.begin(io);
    var owner: Pump = .{ .terminal = &terminal, .editor = .{ .buffer = &storage } };
    terminal.pump = .{ .context = &owner, .service = Pump.service };
    const outcome = drive(io, &terminal, &owner);
    try terminal.finish(io); // cleanup/restore errors take precedence
    const accepted = try outcome;
    if (accepted) |bytes| {
        try std.Io.File.stdout().writeStreamingAll(io, "\r\naccepted:");
        try std.Io.File.stdout().writeStreamingAll(io, bytes);
        try std.Io.File.stdout().writeStreamingAll(io, "\r\n");
    }
}

// Final storage outlives drive and finish, including the borrowed accepted view.
var storage: [65536]u8 = undefined;

const Pump = struct {
    terminal: *Editor.Terminal,
    editor: Editor,
    submitted: bool = false,
    detached: bool = false,
    dirty: bool = false,
    retry: bool = false,
    approve: bool = false,
    cleanup_storage: [4]u8 = undefined,
    cleanup_parser: ?Editor = null,

    fn service(context: *anyopaque, io: std.Io, _: i32) !void {
        const self: *Pump = @ptrCast(@alignCast(context));
        if (self.submitted or self.detached) {
            if (self.cleanup_parser == null) self.cleanup_parser = .{ .buffer = &self.cleanup_storage };
            const parser = &self.cleanup_parser.?;
            try self.cleanupInput(try self.terminal.next(io, parser.pending()));
            return;
        }
        switch (try self.terminal.next(io, self.editor.pending())) {
            .tick => {},
            .timeout => try self.editor.expire(),
            .physical_eof => return error.IncompleteTerminalLine,
            .retry => self.retry = true,
            .approve => self.approve = true,
            .byte => |byte| switch (self.editor.feed(byte)) {
                .none => {},
                .append, .redraw => self.dirty = true,
                .submit => self.submitted = true,
                .eof => self.detached = true,
                .interrupt => return error.InteractiveInterrupted,
                .invalid => return error.InvalidTerminalInput,
                .overflow => return error.TerminalInputOverflow,
            },
        }
    }

    // Drain/disable still observe input, but never loan the accepted bank.
    // This does not choose NOW restoration or persistent cancellation policy.
    fn cleanupInput(self: *Pump, input: Editor.Terminal.Input) !void {
        const parser = &self.cleanup_parser.?;
        switch (input) {
            .tick, .retry, .approve => {},
            .timeout => try parser.expire(),
            .physical_eof => return error.IncompleteTerminalLine,
            .byte => |byte| {
                if (byte == 3) return error.InteractiveInterrupted;
                parser.length = 0;
                parser.cursor = 0;
                parser.rejected = null; // no draft acceptance/rejection authority here
                _ = parser.feed(byte);
            },
        }
    }
};

fn drive(io: std.Io, terminal: *Editor.Terminal, owner: *Pump) !?[]const u8 {
    const editor = &owner.editor;
    try terminal.redraw(io, editor.buffer[0..editor.length], editor.cursor, "Rui ready");
    while (true) {
        if (owner.submitted) return editor.buffer[0..editor.length];
        if (owner.detached) return null;
        if (owner.retry or owner.approve) {
            const retry = owner.retry;
            if (retry) owner.retry = false else owner.approve = false;
            try terminal.writePermanent(io, if (retry) "retry requested\r\n" else "approval requested\r\n");
            owner.dirty = true;
        }
        if (owner.dirty) {
            owner.dirty = false;
            try terminal.redraw(io, editor.buffer[0..editor.length], editor.cursor, "Rui ready");
            continue;
        }
        const event = try terminal.next(io, editor.pending());
        switch (event) {
            .tick => {},
            .timeout => try editor.expire(),
            .physical_eof => return error.IncompleteTerminalLine,
            .retry, .approve => {
                try terminal.writePermanent(io, if (event == .retry) "retry requested\r\n" else "approval requested\r\n");
                try terminal.redraw(io, editor.buffer[0..editor.length], editor.cursor, "Rui ready");
            },
            .byte => |byte| switch (editor.feed(byte)) {
                .none => {},
                .append, .redraw => try terminal.redraw(io, editor.buffer[0..editor.length], editor.cursor, "Rui ready"),
                .submit => {
                    owner.submitted = true;
                    return editor.buffer[0..editor.length];
                },
                .eof => {
                    owner.detached = true;
                    return null;
                },
                .interrupt => return error.InteractiveInterrupted,
                .invalid => return error.InvalidTerminalInput,
                .overflow => return error.TerminalInputOverflow,
            },
        }
    }
}

test "cleanup input observes interruption EOF and incomplete input without changing acceptance" {
    var accepted = "accepted".*;
    var terminal: Editor.Terminal = .{ .original = undefined };
    var owner: Pump = .{ .terminal = &terminal, .editor = .{ .buffer = &accepted, .length = accepted.len, .cursor = accepted.len }, .submitted = true };
    owner.cleanup_parser = .{ .buffer = &owner.cleanup_storage };
    for ("ordinary\x1b[200~paste\x1b[201~") |byte| try owner.cleanupInput(.{ .byte = byte });
    try std.testing.expectEqualStrings("accepted", &accepted);
    try std.testing.expectError(error.InteractiveInterrupted, owner.cleanupInput(.{ .byte = 3 }));
    try std.testing.expectError(error.IncompleteTerminalLine, owner.cleanupInput(.physical_eof));
    for ("\x1b[") |byte| try owner.cleanupInput(.{ .byte = byte });
    try std.testing.expectError(error.IncompleteTerminalInput, owner.cleanupInput(.timeout));
    try std.testing.expectEqualStrings("accepted", &accepted);
}
