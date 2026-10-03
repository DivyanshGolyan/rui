const std = @import("std");
const Self = @import("SessionTerminal.zig");
const Editor = @import("TerminalEditor.zig");
const native = @cImport({
    @cDefine("_XOPEN_SOURCE", "700");
    @cInclude("termios.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
});

test "SessionTerminal output and independent choice do not reset draft parser" {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const flags: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .ACCMODE = .RDWR, .NOCTTY = true })));
    const master = native.posix_openpt(flags);
    if (master < 0) return error.TestPtyOpenFailed;
    defer _ = native.close(master);
    if (native.grantpt(master) != 0 or native.unlockpt(master) != 0) return error.TestPtyOpenFailed;
    const slave = std.c.open(native.ptsname(master) orelse return error.TestPtyOpenFailed, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (slave < 0) return error.TestPtyOpenFailed;
    defer _ = native.close(slave);
    var size: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(slave, @intCast(std.c.T.IOCSWINSZ), &size) != 0) return error.TestPtySizeFailed;
    const original = try std.posix.tcgetattr(slave);
    const saved_stdin = std.c.dup(0);
    if (saved_stdin < 0) return error.TestDupFailed;
    defer _ = native.close(saved_stdin);
    const saved_stdout = std.c.dup(1);
    if (saved_stdout < 0) return error.TestDupFailed;
    defer _ = native.close(saved_stdout);
    if (std.c.dup2(slave, 0) < 0) return error.TestRedirectFailed;
    defer std.debug.assert(std.c.dup2(saved_stdin, 0) == 0);
    if (std.c.dup2(slave, 1) < 0) return error.TestRedirectFailed;
    defer std.debug.assert(std.c.dup2(saved_stdout, 1) == 1);

    var ready: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&ready) != 0) return error.TestPipeFailed;
    defer _ = native.close(ready[0]);
    defer _ = native.close(ready[1]);
    var fd_text: [32]u8 = undefined;
    const fd = try std.fmt.bufPrintZ(&fd_text, "{d}", .{ready[1]});
    if (native.setenv("RUI_TEST_ACTION_READY_FD", fd, 1) != 0) return error.TestEnvironmentFailed;
    defer _ = native.unsetenv("RUI_TEST_ACTION_READY_FD");
    const child = std.c.fork();
    if (child < 0) return error.TestForkFailed;
    if (child == 0) {
        var fds = [_]std.posix.pollfd{.{ .fd = ready[0], .events = std.posix.POLL.IN, .revents = 0 }};
        if ((std.posix.poll(&fds, 5000) catch 0) != 1) std.c._exit(20);
        var notice: [1]u8 = undefined;
        if ((std.posix.read(ready[0], &notice) catch 0) != 1) std.c._exit(21);
        // The production ready boundary follows the input flush: this is a
        // fresh choice, not typeahead accidentally accepted during setup.
        const input = "a\r";
        if (std.c.write(master, input.ptr, input.len) != input.len) std.c._exit(22);
        std.c._exit(0);
    }
    defer {
        var status: c_int = undefined;
        std.debug.assert(std.c.waitpid(child, &status, 0) == child);
    }
    var buffers: [2][65536]u8 = undefined;
    var owner: Self = undefined;
    try owner.init(std.Io.Threaded.global_single_threaded.io(), &buffers);
    defer owner.close() catch unreachable;
    // Non-tail cursor plus an unfinished marked-paste terminator: continuation
    // after approval must resume the ordinary parser, not a new Editor.
    for ("xy\x1b[D\x1b[200~a\n\x1b[20") |byte| _ = owner.editor.feed(byte);
    try std.testing.expectEqualStrings("xa\ny", owner.draft());
    try std.testing.expectEqual(@as(usize, 3), owner.editor.cursor);
    owner.beginApproval();
    try owner.beginOutput();
    try std.testing.expectEqualStrings("a", (try owner.readChoice("Choice: ")).?);
    owner.finishApproval();
    try std.testing.expectEqualStrings("xa\ny", owner.draft());
    try std.testing.expectEqual(@as(usize, 3), owner.editor.cursor);
    try std.testing.expect(owner.editor.paste);
    try std.testing.expectEqual(@as(usize, 4), owner.editor.paste_prefix_length);
    for ("1~b") |byte| _ = owner.editor.feed(byte);
    try std.testing.expectEqual(Editor.Event.submit, owner.editor.feed('\r'));
    try std.testing.expectEqualStrings("xa\nby", owner.draft());
    try owner.close();
    try std.testing.expectEqualDeep(original, try std.posix.tcgetattr(slave));
}

test "SessionTerminal native EOF is fatal in draft staging and fresh choice" {
    const saved_stdin = std.c.dup(0);
    if (saved_stdin < 0) return error.TestDupFailed;
    defer _ = std.c.close(saved_stdin);
    var pipe: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&pipe) != 0) return error.TestPipeFailed;
    defer _ = std.c.close(pipe[0]);
    _ = std.c.close(pipe[1]);
    if (std.c.dup2(pipe[0], 0) < 0) return error.TestRedirectFailed;
    defer std.debug.assert(std.c.dup2(saved_stdin, 0) == 0);
    var buffer: [16]u8 = undefined;
    var owner: Self = .{ .io = std.testing.io, .editor = .{ .buffer = &buffer }, .spare = &.{}, .original = undefined, .raw = undefined, .size = undefined };
    try std.testing.expectError(error.TerminalInputClosed, owner.service(0));
    owner.beginApproval();
    try std.testing.expectError(error.TerminalInputClosed, owner.service(0));
    owner.finishApproval();
    _ = owner.editor.feed('x');
    try std.testing.expectError(error.IncompleteTerminalLine, owner.service(0));
    owner.clearDraft();
    // Explicit typed detachment remains distinct from physical input closure.
    try std.testing.expectEqual(Editor.Event.eof, owner.editor.feed(4));
    try std.testing.expectEqual(Editor.Event.interrupt, owner.editor.feed(3));
    try freshChoiceEof(pipe[0]);
}

fn freshChoiceEof(eof_fd: std.posix.fd_t) !void {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const flags: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .ACCMODE = .RDWR, .NOCTTY = true })));
    const master = native.posix_openpt(flags);
    if (master < 0) return error.TestPtyOpenFailed;
    defer _ = native.close(master);
    if (native.grantpt(master) != 0 or native.unlockpt(master) != 0) return error.TestPtyOpenFailed;
    const slave = std.c.open(native.ptsname(master) orelse return error.TestPtyOpenFailed, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (slave < 0) return error.TestPtyOpenFailed;
    defer _ = native.close(slave);
    var size: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(slave, @intCast(std.c.T.IOCSWINSZ), &size) != 0) return error.TestPtySizeFailed;
    const saved_stdout = std.c.dup(1);
    if (saved_stdout < 0) return error.TestDupFailed;
    defer _ = native.close(saved_stdout);
    if (std.c.dup2(slave, 0) < 0 or std.c.dup2(slave, 1) < 0) return error.TestRedirectFailed;
    defer std.debug.assert(std.c.dup2(saved_stdout, 1) == 1);
    var ready: [2]std.posix.fd_t = undefined;
    if (std.c.pipe(&ready) != 0) return error.TestPipeFailed;
    defer _ = native.close(ready[0]);
    defer _ = native.close(ready[1]);
    var fd_text: [32]u8 = undefined;
    const fd = try std.fmt.bufPrintZ(&fd_text, "{d}", .{ready[1]});
    if (native.setenv("RUI_TEST_ACTION_READY_FD", fd, 1) != 0) return error.TestEnvironmentFailed;
    defer _ = native.unsetenv("RUI_TEST_ACTION_READY_FD");
    var buffers: [2][65536]u8 = undefined;
    var owner: Self = undefined;
    try owner.init(std.Io.Threaded.global_single_threaded.io(), &buffers);
    defer {
        // Restore the actual terminal descriptor before returning its custody.
        std.debug.assert(std.c.dup2(slave, 0) == 0);
        owner.close() catch unreachable;
    }
    owner.beginApproval();
    try owner.beginOutput();
    // The helper changes only the input adapter after production has drained
    // and flushed the PTY and entered fresh choice; no private transition API.
    const helper = try std.Thread.spawn(.{}, closeChoiceInput, .{ ready[0], eof_fd });
    defer helper.join();
    try std.testing.expectError(error.TerminalInputClosed, owner.readChoice("Choice: "));
}

fn closeChoiceInput(ready_fd: std.posix.fd_t, eof_fd: std.posix.fd_t) void {
    var fds = [_]std.posix.pollfd{.{ .fd = ready_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    std.debug.assert((std.posix.poll(&fds, 5000) catch 0) == 1);
    var notice: [1]u8 = undefined;
    std.debug.assert((std.posix.read(ready_fd, &notice) catch 0) == 1);
    std.debug.assert(std.c.dup2(eof_fd, 0) == 0);
}

test "SessionTerminal failed stdout restores native PTY on init" {
    try failedStdoutRestoration(false);
}

test "SessionTerminal failed stdout restores native PTY on resume" {
    try failedStdoutRestoration(true);
}

fn failedStdoutRestoration(resuming: bool) !void {
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const flags: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .ACCMODE = .RDWR, .NOCTTY = true })));
    const master = native.posix_openpt(flags);
    if (master < 0) return error.TestPtyOpenFailed;
    defer _ = native.close(master);
    if (native.grantpt(master) != 0 or native.unlockpt(master) != 0) return error.TestPtyOpenFailed;
    const name = native.ptsname(master) orelse return error.TestPtyOpenFailed;
    const slave = std.c.open(name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (slave < 0) return error.TestPtyOpenFailed;
    defer _ = native.close(slave);
    const original = try std.posix.tcgetattr(slave);
    try std.testing.expect(original.lflag.ICANON and original.lflag.ECHO and original.lflag.ISIG);
    const child = std.c.fork();
    if (child < 0) return error.TestForkFailed;
    if (child == 0) {
        if (std.c.dup2(slave, 0) < 0 or std.c.dup2(slave, 1) < 0 or std.c.dup2(slave, 2) < 0) std.c._exit(20);
        var buffers: [2][65536]u8 = undefined;
        const io = std.Io.Threaded.global_single_threaded.io();
        var owner: Self = undefined;
        if (resuming) {
            owner.init(io, &buffers) catch std.c._exit(21);
            owner.@"suspend"() catch std.c._exit(22);
        }
        // A valid read-only descriptor passes GETFL/SETFL but fails the
        // paste-enable write only AFTER raw installation.
        const readonly = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
        if (readonly < 0 or std.c.dup2(readonly, 1) < 0) std.c._exit(24);
        _ = native.close(readonly);
        const output_flags = std.c.fcntl(1, std.c.F.GETFL);
        const error_flags = std.c.fcntl(2, std.c.F.GETFL);
        const result = if (resuming) owner.@"resume"() else owner.init(io, &buffers);
        if (result) |_| std.c._exit(23) else |err| {
            if (err != error.TerminalCleanupFailed) std.c._exit(25);
        }
        if (owner.active) std.c._exit(26);
        if (std.c.fcntl(1, std.c.F.GETFL) != output_flags or std.c.fcntl(2, std.c.F.GETFL) != error_flags) std.c._exit(27);
        std.c._exit(0);
    }
    var status: c_int = undefined;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    try std.testing.expectEqual(@as(c_int, 0), status);
    const restored = try std.posix.tcgetattr(slave);
    try std.testing.expectEqualDeep(original, restored);
}

test "SessionTerminal initialization input borrows final command storage" {
    try initializationStorage(false);
}

test "SessionTerminal initialization input borrows final focus storage" {
    try initializationStorage(true);
}

fn initializationStorage(focus: bool) !void {
    // Run with terminal_init_probe.c preloaded: native raw installation is
    // the input scheduling boundary, not prequeued bytes lost by TCSAFLUSH.
    if (@import("builtin").os.tag != .linux or std.c.getenv("RUI_INIT_PROBE") == null or std.c.getenv("LD_PRELOAD") == null) return error.SkipZigTest;
    const flags: c_int = @bitCast(@as(u32, @bitCast(std.c.O{ .ACCMODE = .RDWR, .NOCTTY = true })));
    const master = native.posix_openpt(flags);
    if (master < 0) return error.TestPtyOpenFailed;
    defer _ = native.close(master);
    if (native.grantpt(master) != 0 or native.unlockpt(master) != 0) return error.TestPtyOpenFailed;
    const slave = std.c.open(native.ptsname(master) orelse return error.TestPtyOpenFailed, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (slave < 0) return error.TestPtyOpenFailed;
    defer _ = native.close(slave);
    const original = try std.posix.tcgetattr(slave);
    const child = std.c.fork();
    if (child < 0) return error.TestForkFailed;
    if (child == 0) {
        if (std.c.dup2(slave, 0) < 0 or std.c.dup2(slave, 1) < 0 or std.c.dup2(slave, 2) < 0) std.c._exit(20);
        var text: [32]u8 = undefined;
        const fd = std.fmt.bufPrintZ(&text, "{d}", .{master}) catch std.c._exit(21);
        if (native.setenv("RUI_INIT_MASTER_FD", fd, 1) != 0 or native.setenv("RUI_INIT_INPUT", if (focus) "\x07" else "/status\n", 1) != 0) std.c._exit(22);
        var buffers: [2][65536]u8 = undefined;
        var owner: Self = undefined;
        owner.init(std.Io.Threaded.global_single_threaded.io(), &buffers) catch std.c._exit(23);
        if (focus) {
            if (owner.focus != .staging or owner.pending_focus != .approve) std.c._exit(24);
            if (owner.focus_editor.buffer.ptr != &owner.focus_buffer) std.c._exit(25);
            if (std.c.write(master, "l", 1) != 1) std.c._exit(26);
            owner.service(100) catch std.c._exit(26);
            if (!std.mem.eql(u8, owner.focus_buffer[0..owner.focus_editor.length], "l")) std.c._exit(27);
        } else {
            if (owner.pending_focus != .command) std.c._exit(28);
            if (owner.pending_focus.command.ptr != &owner.command_buffer) std.c._exit(29);
            if (!std.mem.eql(u8, owner.pending_focus.command, "/status")) std.c._exit(30);
            owner.finishCommand();
        }
        owner.close() catch std.c._exit(31);
        std.c._exit(0);
    }
    var status: c_int = undefined;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    try std.testing.expectEqual(@as(c_int, 0), status);
    try std.testing.expectEqualDeep(original, try std.posix.tcgetattr(slave));
}
