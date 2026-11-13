//! The terminal outside the full-screen app: prompts read from the shell's
//! own terminal, its modes, and validation of literal command-line text.
//! The draft editor is DraftEditor, over libvaxis's TextArea.
const std = @import("std");
const termios = @import("posix");

// libc's termios is not the Linux kernel ABI used by std.posix.termios.
// Keep the native type at this boundary, including speeds and all cc entries.
pub const Attributes = termios.struct_termios;

pub fn getAttributes() std.posix.TermiosGetError!Attributes {
    var attributes: Attributes = undefined;
    while (true) switch (std.posix.errno(termios.tcgetattr(0, &attributes))) {
        .SUCCESS => return attributes,
        .INTR => {},
        .BADF => unreachable,
        .NOTTY => return error.NotATerminal,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

/// Puts the terminal in prompt mode: bytes arrive one at a time, unechoed,
/// with no line editing, flow control or signals (Ctrl+C is a byte). Returns
/// the attributes `leavePromptMode` restores.
fn enterPromptMode() !Attributes {
    const original = try getAttributes();
    var mode = original;
    mode.c_lflag &= ~@as(termios.tcflag_t, termios.ICANON | termios.ECHO | termios.ISIG | termios.IEXTEN);
    mode.c_iflag &= ~@as(termios.tcflag_t, termios.IXON);
    mode.c_cc[termios.VMIN] = 1;
    mode.c_cc[termios.VTIME] = 0;
    try setAttributes(.FLUSH, mode);
    return original;
}

/// Discards the prompt's queued input and restores `original` exactly.
/// NOW would also leave Darwin's PENDIN set when re-entering canonical mode.
fn leavePromptMode(original: Attributes) error{TerminalRestoreFailed}!void {
    setAttributes(.FLUSH, original) catch return error.TerminalRestoreFailed;
}

/// One line from the terminal with nothing shown, for a secret. Enter ends
/// it, Backspace edits it, Ctrl+C cancels it and Ctrl+D on an empty line is
/// null. No line is returned unless the terminal's own
/// settings were restored. The caller zeroes `buffer`.
pub fn readSecretLine(io: std.Io, buffer: []u8, prompt: []const u8) !?[]const u8 {
    const original = try enterPromptMode();
    const result = secretLine(io, buffer, prompt);
    try leavePromptMode(original);
    return result;
}

fn secretLine(io: std.Io, buffer: []u8, prompt: []const u8) !?[]const u8 {
    // Prompt only once echo is off, so a key typed the moment the prompt
    // shows is never echoed.
    try std.Io.File.stdout().writeStreamingAll(io, prompt);
    var chunk: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &chunk);
    var length: usize = 0;
    errdefer std.crypto.secureZero(u8, buffer[0..length]);
    while (true) {
        const count = std.Io.File.stdin().readStreaming(io, &.{&chunk}) catch |err| switch (err) {
            error.EndOfStream => return if (length == 0) null else buffer[0..length],
            else => return err,
        };
        for (chunk[0..count]) |byte| switch (byte) {
            '\r', '\n' => return buffer[0..length],
            0x03 => return error.SecretEntryInterrupted,
            0x04 => if (length == 0) return null,
            0x08, 0x7f => length -|= 1,
            else => {
                if (length == buffer.len) return error.StreamTooLong;
                buffer[length] = byte;
                length += 1;
            },
        };
    }
}

pub fn setAttributes(action: std.posix.TCSA, attributes: Attributes) std.posix.TermiosSetError!void {
    while (true) switch (std.posix.errno(termios.tcsetattr(0, @intCast(@backingInt(action)), &attributes))) {
        .SUCCESS => return,
        .INTR => {},
        .BADF, .INVAL => unreachable,
        .NOTTY => return error.NotATerminal,
        .IO => return error.ProcessOrphaned,
        else => |err| return std.posix.unexpectedErrno(err),
    };
}

/// Returns a slice borrowed from buffer until its caller next reuses it.
/// The shell's canonical terminal handles editing, echo and signals.
pub fn readLine(io: std.Io, buffer: []u8, prompt: []const u8) !?[]const u8 {
    try std.Io.File.stdout().writeStreamingAll(io, prompt);
    try freshChoice(io);
    var length: usize = 0;
    var overflow = false;
    while (true) {
        var byte: [1]u8 = undefined;
        _ = std.Io.File.stdin().readStreaming(io, &.{&byte}) catch |err| switch (err) {
            error.EndOfStream => return if (overflow) error.StreamTooLong else if (length == 0) null else buffer[0..length],
            else => return err,
        };
        if (byte[0] == '\n') return if (overflow) error.StreamTooLong else buffer[0..length];
        if (length == buffer.len) {
            overflow = true;
        } else {
            buffer[length] = byte[0];
            length += 1;
        }
    }
}

/// Complete presentation, then discard pre-prompt input before consent.
pub fn freshChoice(io: std.Io) !void {
    if (termios.tcdrain(1) != 0 or termios.tcflush(0, termios.TCIFLUSH) != 0) return error.TerminalFlushFailed;
    try testChoiceReady(io);
}

pub fn testChoiceReady(io: std.Io) !void {
    // Borrowed fixture descriptor witnesses the completed input boundary.
    if (std.c.getenv("RUI_TEST_ACTION_READY_FD")) |text| {
        const fd = try std.fmt.parseInt(std.posix.fd_t, std.mem.span(text), 10);
        const ready: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
        try ready.writeStreamingAll(io, "x");
    }
}
