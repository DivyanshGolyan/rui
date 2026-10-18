//! Bounded public Activity presentation with one forward-only content pass.
//! A failed stream may leave a visible prefix; the terminal owner must not retry it.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Text = @import("TerminalText.zig");
const Renderer = @import("AnswerRenderer.zig");
const tools = @import("tools.zig");

/// Only presentation-owned foreground changes. Content cannot select a style.
pub const Style = enum {
    user,
    quiet,
    attention,
    failure,
    normal,

    pub fn code(self: Style, colour: bool) []const u8 {
        if (!colour) return "";
        return switch (self) {
            .user => "\x1b[94m",
            .quiet => "\x1b[90m",
            .attention => "\x1b[33m",
            .failure => "\x1b[91m",
            .normal => "\x1b[39m",
        };
    }
};

fn toolState(code: protocol.ToolPresentation.Code) struct { glyph: []const u8, suffix: []const u8, style: Style } {
    return switch (code) {
        .unresolved => .{ .glyph = "•", .suffix = "", .style = .quiet },
        .pending_permission => .{ .glyph = "?", .suffix = "", .style = .attention },
        .succeeded => .{ .glyph = "✓", .suffix = "", .style = .normal },
        .denied => .{ .glyph = "•", .suffix = " — Denied", .style = .normal },
        .unknown_tool => .{ .glyph = "•", .suffix = " — Rejected: unknown tool", .style = .normal },
        .invalid_arguments => .{ .glyph = "•", .suffix = " — Rejected: invalid arguments", .style = .normal },
        .tool_unavailable => .{ .glyph = "•", .suffix = " — Rejected: tool unavailable", .style = .normal },
        .failed => .{ .glyph = "!", .suffix = " — Failed", .style = .failure },
        .timed_out => .{ .glyph = "!", .suffix = " — Timed out", .style = .failure },
        .indeterminate => .{ .glyph = "!", .suffix = " — Outcome unknown; may have run", .style = .failure },
        .storage_failed => .{ .glyph = "!", .suffix = " — Output capture failed", .style = .failure },
        .spawn_failed => .{ .glyph = "!", .suffix = " — Could not start", .style = .failure },
        .cancelled => .{ .glyph = "!", .suffix = " — Cancelled", .style = .failure },
        .infrastructure_shutdown => .{ .glyph = "!", .suffix = " — Host stopped; outcome unknown", .style = .failure },
    };
}

pub fn toolHeading(presentation: protocol.ToolPresentation, sink: anytype, colour: bool, separate: bool) !void {
    return toolHeadingWith(presentation, sink, colour, separate, "");
}

/// `exit` is a digits-only exit status, shown after the failure suffix.
fn toolHeadingWith(presentation: protocol.ToolPresentation, sink: anytype, colour: bool, separate: bool, exit: []const u8) !void {
    const state = toolState(presentation.code);
    if (separate) try sink.feed("\n");
    try sink.feed(state.style.code(colour));
    try sink.feed(state.glyph);
    try sink.feed(Style.normal.code(colour));
    try sink.feed(" ");
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    var escaped: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .line } };
    try escaped.feed(if (presentation.description) |label| label.slice() else "Tool call");
    try escaped.finish();
    try indented.feed(state.suffix);
    if (exit.len != 0) {
        try indented.feed(" (exit ");
        try indented.feed(exit);
        try indented.feed(")");
    }
    try indented.finish();
    try sink.feed("\n");
}

/// Presentation of the Store-owned, cursor-relative Activity capture.
pub const Live = struct {
    pub const Entry = protocol.CallActivity.Entry;
    entries: [3]Entry = undefined,
    count: usize = 0,
    total: u64 = 0,

    pub fn init(facts: protocol.CallActivity) Live {
        return .{ .entries = facts.entries, .count = facts.count, .total = facts.total };
    }

    // Worst terminal escaping is four bytes per input byte; allow glyph/suffix.
    pub const line_bytes = 4 * protocol.max_tool_description_bytes + 96;
    pub fn line(self: *const Live, index: usize, buffer: *[line_bytes]u8) ![]const u8 {
        const entry = self.entries[index];
        const state = toolState(entry.presentation.code);
        var writer = std.Io.Writer.fixed(buffer);
        try writer.print("{s} ", .{state.glyph});
        var text: Text = .{ .mode = .line };
        try text.feed(&writer, if (entry.presentation.description) |label| label.slice() else "Tool call");
        try text.finish(&writer);
        try writer.writeAll(state.suffix);
        return writer.buffered();
    }

    pub fn style(self: *const Live, index: usize) Style {
        return toolState(self.entries[index].presentation.code).style;
    }
};

/// Live conversation and inspection share hanging indentation. Input is already
/// escaped or rendered; cell layout owns wrapping in the alternate screen.
pub fn Indented(comptime Sink: type) type {
    return struct {
        sink: Sink,
        line_start: bool = false,
        sgr: bool = false,
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            var storage: [4096]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            for (bytes) |byte| {
                if (storage.len - out.end < 3) {
                    try self.sink.feed(out.buffered());
                    out.end = 0;
                }
                if (self.line_start and byte != '\n') {
                    try out.writeAll("  ");
                    self.line_start = false;
                }
                if (self.sgr or byte == 0x1b) {
                    self.sgr = byte != 'm';
                } else if (byte == '\n') self.line_start = true;
                try out.writeByte(byte);
            }
            if (out.end != 0) try self.sink.feed(out.buffered());
        }
        pub fn finish(self: *@This()) !void {
            if (self.sgr) return error.IncompleteRenderedText;
        }
    };
}

test "hanging indentation survives split windows and trusted styles" {
    const Sink = struct {
        bytes: [128]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const input = "first\n\x1b[1msecond\x1b[0m\n\nthird";
    for (0..input.len + 1) |split| {
        var sink: Sink = .{};
        var presentation: Indented(*Sink) = .{ .sink = &sink };
        try presentation.feed(input[0..split]);
        try presentation.feed(input[split..]);
        try presentation.finish();
        try std.testing.expectEqualStrings("first\n  \x1b[1msecond\x1b[0m\n\n  third", sink.bytes[0..sink.length]);
    }
}

pub fn permission(requests: client.Requests, store: []const u8, session: []const u8, action: u64, workspace: []const u8, scratch: std.Io.File, sink: anytype, colour: bool) !void {
    // Action reads write at the descriptor's streaming offset, not positionally.
    try requests.io.vtable.fileSeekTo(requests.io.userdata, scratch, 0);
    try scratch.setLength(requests.io, 0);
    var reply: client.ReplyBuffer = .{};
    const result = try requests.readActionArguments(store, session, action, scratch, &reply);
    if (result == .command) {
        const failure = requests.captureReadFailure(result.command) catch {
            try client.checkCanonicalFailure(result.command);
            return error.ActionReadFailed;
        };
        if (failure.err() == error.CanonicalStoreFailure) return error.CanonicalStoreFailure;
        return error.ActionReadFailed;
    }
    var buffer: [4096]u8 = undefined;
    var reader = scratch.reader(requests.io, &buffer);
    const Source = struct {
        reader: *std.Io.Reader,
        pub fn peek(self: *@This()) !?u8 {
            return self.reader.peekByte() catch |err| switch (err) {
                error.EndOfStream => null,
                else => return err,
            };
        }
        pub fn take(self: *@This()) !u8 {
            return self.reader.takeByte();
        }
    };
    var source: Source = .{ .reader = &reader.interface };
    const arguments = try tools.inspectBashArguments(&source) orelse return error.InvalidBashArguments;
    try reader.seekTo(0);
    // Where and how long first, then the exact command; the description is
    // the model's label, never a substitute for the command.
    try sink.feed("\n");
    try sink.feed(Style.attention.code(colour));
    try sink.feed("? Run Bash");
    try sink.feed(Style.normal.code(colour));
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    if (arguments.description.len != 0) {
        try indented.feed(" · ");
        var label: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .line } };
        try label.feed(arguments.description.slice());
        try label.finish();
    }
    try indented.feed("\nWorkspace: ");
    var location: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .line } };
    try location.feed(workspace);
    try location.finish();
    if (arguments.timeout_ms) |timeout| {
        try print(&indented, "\nTime limit: {d} ms", .{timeout});
    } else try indented.feed("\nTime limit: Host default");
    try indented.feed("\n$ ");
    var command: Indented(*Indented(@TypeOf(sink))) = .{ .sink = &indented };
    var escaped: Escaped(@TypeOf(&command)) = .{ .sink = &command, .text = .{ .mode = .multiline } };
    if (!try tools.writeBashCommand(&source, &escaped)) return error.InvalidBashArguments;
    try escaped.finish();
    try command.finish();
    try indented.feed("\n");
    try indented.finish();
}

pub fn current(requests: client.Requests, store: []const u8, session: []const u8, scratch: std.Io.File) !client.Current {
    try scratch.setLength(requests.io, 0);
    const Capture = struct {
        io: std.Io,
        file: std.Io.File,
        offset: u64 = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset += bytes.len;
        }
    };
    var capture: Capture = .{ .io = requests.io, .file = scratch };
    var reply: client.ReplyBuffer = .{};
    const report = try requests.inspectSession(store, session, .current, &capture, &reply);
    return switch (try client.CurrentReply.decode(requests.io, scratch, session, report)) {
        .current => |value| value,
        .unconfigured => error.SessionNotConfigured,
        .failure => |failure| requests.failRead(failure),
    };
}

pub fn Escaped(comptime Sink: type) type {
    return struct {
        sink: Sink,
        text: Text,
        storage: [256]u8 = undefined,
        used: usize = 0,
        pub fn writeAll(self: *@This(), bytes: []const u8) anyerror!void {
            try self.feed(bytes);
        }
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            var out = std.Io.Writer.fixed(&self.storage);
            out.end = self.used;
            for (bytes) |byte| {
                if (self.storage.len - out.end < 16) {
                    try self.sink.feed(out.buffered());
                    out.end = 0;
                }
                try self.text.feed(&out, &.{byte});
            }
            self.used = out.end;
        }
        pub fn finish(self: *@This()) anyerror!void {
            var out = std.Io.Writer.fixed(&self.storage);
            out.end = self.used;
            if (self.storage.len - out.end < 16) {
                try self.sink.feed(out.buffered());
                out.end = 0;
            }
            try self.text.finish(&out);
            if (out.end != 0) try self.sink.feed(out.buffered());
            self.used = 0;
        }
    };
}

/// Initialize in final storage: Renderer borrows the embedded Writer. Preserve
/// the original rendezvous error rather than narrowing Cancelled to WriteFailed.
pub fn Answer(comptime Sink: type) type {
    return struct {
        sink: Sink,
        storage: [4096]u8 = undefined,
        writer: std.Io.Writer,
        renderer: Renderer,
        failure: ?anyerror = null,
        pub fn init(self: *@This(), sink: Sink) void {
            self.* = .{ .sink = sink, .writer = undefined, .renderer = undefined };
            self.writer = .{ .vtable = &.{ .drain = drain }, .buffer = &self.storage };
            self.renderer = .{ .out = &self.writer };
        }
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            if (self.failure) |err| return err;
            self.renderer.feed(bytes) catch |err| return self.failure orelse err;
            self.writer.flush() catch |err| return self.failure orelse err;
        }
        pub fn finish(self: *@This()) anyerror!void {
            if (self.failure) |err| return err;
            self.renderer.finish() catch |err| return self.failure orelse err;
            self.writer.flush() catch |err| return self.failure orelse err;
        }
        fn forward(self: *@This(), bytes: []const u8) std.Io.Writer.Error!void {
            if (bytes.len == 0) return;
            self.sink.feed(bytes) catch |err| {
                self.failure = err;
                return error.WriteFailed;
            };
        }
        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            const self: *@This() = @fieldParentPtr("writer", writer);
            try self.forward(writer.buffered());
            writer.end = 0;
            var consumed: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| {
                try self.forward(bytes);
                consumed += bytes.len;
            }
            const last = data[data.len - 1];
            for (0..splat) |_| try self.forward(last);
            return consumed + last.len * splat;
        }
    };
}

fn print(sink: anytype, comptime format: []const u8, args: anytype) !void {
    var storage: [256]u8 = undefined;
    try sink.feed(try std.fmt.bufPrint(&storage, format, args));
}

/// Exact fixed-end summary requires a metadata walk, not Current or the newest
/// page. Retain only the oldest four identities; never retain history payloads.
pub const Pending = struct {
    total: u64 = 0,
    count: usize = 0,
    items: [4]struct { position: u64, ordinal: u64, content: protocol.ActivityItem.Content } = undefined,

    pub fn render(self: *const Pending, requests: client.Requests, store: []const u8, session: []const u8, sink: anytype) !void {
        if (self.total == 0) return;
        try print(sink, "Rui: {d} queued messages.\n", .{self.total});
        const Preview = struct {
            escaped: Escaped(@TypeOf(sink)),
            remaining: usize = 256,
            omitted: bool = false,
            pub fn feed(self_: *@This(), bytes: []const u8) !void {
                const count = @min(self_.remaining, bytes.len);
                try self_.escaped.feed(bytes[0..count]);
                self_.remaining -= count;
                self_.omitted = self_.omitted or count != bytes.len;
            }
        };
        for (self.items[0..self.count]) |item| {
            try sink.feed("Queued: ");
            var preview: Preview = .{ .escaped = .{ .sink = sink, .text = .{ .mode = .line } } };
            if (try requests.readActivityContent(store, session, item.position, item.ordinal, .{ .bytes = item.content.length, .digest = item.content.digest }, &preview)) |failure| return requests.failRead(failure);
            try preview.escaped.finish();
            if (preview.omitted) try sink.feed(" [preview truncated]");
            try sink.feed("\n");
        }
    }
};

pub fn pending(requests: client.Requests, store: []const u8, session: []const u8, end: u64) !Pending {
    var summary: Pending = .{};
    var cursor: client.ActivityCursor = .{ .end = end };
    while (true) {
        const page = switch (try requests.activityPage(store, session, cursor)) {
            .page => |page| page,
            .failure => |failure| return requests.failRead(failure),
        };
        for (page.facts.items[0..page.facts.count]) |item| {
            if (item.value != .admission or item.value.admission.state != .queued) continue;
            summary.total += 1;
            if (summary.count == summary.items.len) continue;
            summary.items[summary.count] = .{ .position = item.position, .ordinal = item.ordinal, .content = item.value.admission.content };
            summary.count += 1;
        }
        cursor = page.continuation() orelse return summary;
    }
}

fn content(requests: client.Requests, store: []const u8, session: []const u8, item: protocol.ActivityItem, reference: protocol.ActivityItem.Content, sink: anytype) !void {
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink };
    if (item.value == .assistant) {
        var answer: Answer(@TypeOf(&indented)) = undefined;
        answer.init(&indented);
        if (try requests.readActivityContent(store, session, item.position, item.ordinal, .{ .bytes = reference.length, .digest = reference.digest }, &answer)) |failure| return requests.failRead(failure);
        try answer.finish();
    } else {
        var escaped: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .multiline } };
        if (try requests.readActivityContent(store, session, item.position, item.ordinal, .{ .bytes = reference.length, .digest = reference.digest }, &escaped)) |failure| return requests.failRead(failure);
        try escaped.finish();
    }
    try indented.finish();
    try sink.feed("\n");
}

/// Compact tool outcome shared by live Activity and the scrolled transcript.
/// Failures keep their last output lines in view; /details stays exact.
pub fn toolResult(presentation: protocol.ToolPresentation, source: anytype, sink: anytype, colour: bool, compact: *bool) !void {
    const succeeded = presentation.code == .succeeded;
    var summary: Summary(@TypeOf(sink)) = .{
        .presentation = presentation,
        .separate = !compact.* or !succeeded,
        .escaped = .{ .sink = sink, .text = .{ .mode = .multiline } },
        .code = presentation.code,
        .colour = colour,
        .section = switch (presentation.code) {
            .denied, .unknown_tool, .invalid_arguments, .tool_unavailable => .ended,
            else => .summary,
        },
    };
    try source.read(&summary);
    try summary.finish();
    if (summary.emitted) try sink.feed("\n");
    compact.* = succeeded and !summary.emitted;
}

fn failing(code: protocol.ToolPresentation.Code) bool {
    return toolState(code).style == .failure;
}

fn Summary(comptime Sink: type) type {
    return struct {
        const excerpt_lines = 3;
        const line_bytes = 256;
        const Tail = struct {
            // A few lines beyond the excerpt absorb the canonical trailer.
            lines: [excerpt_lines + 6][line_bytes]u8 = undefined,
            lengths: [excerpt_lines + 6]usize = undefined,
            shortened: [excerpt_lines + 6]bool = undefined,
            count: usize = 0,
            total: usize = 0,

            fn push(tail: *@This(), line: []const u8, shortened: bool) void {
                const slot = tail.total % tail.lines.len;
                @memcpy(tail.lines[slot][0..line.len], line);
                tail.lengths[slot] = line.len;
                tail.shortened[slot] = shortened;
                tail.total += 1;
                tail.count = @min(tail.count + 1, tail.lines.len);
            }
            fn last(tail: *const @This(), back: usize) []const u8 {
                const slot = (tail.total - 1 - back) % tail.lines.len;
                return tail.lines[slot][0..tail.lengths[slot]];
            }
            fn dropLast(tail: *@This()) void {
                tail.total -= 1;
                tail.count -= 1;
            }
        };
        escaped: Escaped(Sink),
        // The heading waits for the first detail: a failed exit status joins it.
        presentation: ?protocol.ToolPresentation = null,
        separate: bool = true,
        code: protocol.ToolPresentation.Code,
        colour: bool,
        section: enum { summary, stdout, stderr, ended } = .summary,
        line: [line_bytes]u8 = undefined,
        length: usize = 0,
        emitted: bool = false,
        omitted: bool = false,
        earlier_omitted: bool = false,
        stdout: Tail = .{},
        stderr: Tail = .{},
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            for (bytes) |byte| {
                if (self.section == .ended) return;
                if (byte == '\n') {
                    try self.emit();
                } else if (self.length < self.line.len) {
                    self.line[self.length] = byte;
                    self.length += 1;
                } else {
                    // Shorten only this line; later capture/cleanup
                    // warnings remain visible before output tails.
                    self.omitted = true;
                }
            }
        }
        fn emit(self: *@This()) !void {
            const line = self.line[0..self.length];
            defer {
                self.length = 0;
                self.omitted = false;
            }
            const heading = !self.omitted and (std.mem.eql(u8, line, "stdout tail:") or std.mem.eql(u8, line, "stderr tail:"));
            switch (self.section) {
                .ended => return,
                .stdout, .stderr => |stream| {
                    if (stream == .stdout and heading and std.mem.eql(u8, line, "stderr tail:")) {
                        self.section = .stderr;
                    } else (if (stream == .stdout) &self.stdout else &self.stderr).push(line, self.omitted);
                    return;
                },
                .summary => {},
            }
            // Only complete, known informational lines are quiet. Unknown or
            // qualified diagnostics stay visible, even after successful exit.
            // Keep canonical Bash evidence and detailed inspection unchanged.
            const routine = !self.omitted and
                (std.mem.eql(u8, line, "Bash succeeded. Exit code: 0.") or
                    std.mem.eql(u8, line, "Process retirement confirmed: the child was reaped and the original process group was observed absent. macOS group signaling returned EPERM, which can mean no live targets or permission denial."));
            if (heading) {
                // Output tails matter only to explain a failure.
                self.section = if (!failing(self.code)) .ended else if (std.mem.eql(u8, line, "stdout tail:")) .stdout else .stderr;
            } else if (line.len != 0 and !routine) {
                var prefix_buffer: [64]u8 = undefined;
                const prefix = if (failing(self.code)) try std.fmt.bufPrint(&prefix_buffer, "Bash {s}. ", .{@tagName(self.code)}) else "";
                const detail = if (!self.omitted and prefix.len != 0 and std.mem.startsWith(u8, line, prefix)) line[prefix.len..] else line;
                if (self.presentation != null and !self.emitted and prefix.len != 0 and !self.omitted) {
                    const status = if (std.mem.startsWith(u8, detail, "Exit code: ") and std.mem.endsWith(u8, detail, ".")) detail["Exit code: ".len .. detail.len - 1] else "";
                    var digits = status.len != 0 and status.len <= 3;
                    for (status) |byte| digits = digits and std.ascii.isDigit(byte);
                    if (digits) {
                        try self.writeHeading(status);
                        return;
                    }
                }
                try self.writeHeading("");
                try self.escaped.feed(if (self.emitted) "\n  " else "  ");
                try self.escaped.feed(detail);
                if (self.omitted) try self.escaped.feed(" [summary shortened; /details]");
                self.emitted = true;
            }
        }
        fn writeHeading(self: *@This(), exit: []const u8) !void {
            const presentation = self.presentation orelse return;
            self.presentation = null;
            try toolHeadingWith(presentation, self.escaped.sink, self.colour, self.separate, exit);
        }
        fn finish(self: *@This()) !void {
            if (self.length != 0) try self.emit();
            try self.writeHeading("");
            if (failing(self.code) and self.section != .ended) {
                // Strip the canonical trailer that follows stderr bytes.
                while (self.stderr.count != 0) {
                    const line = self.stderr.last(0);
                    if (line.len == 0 or std.mem.eql(u8, line, "Full output was not retained.") or
                        std.mem.startsWith(u8, line, "Full stdout: ") or std.mem.startsWith(u8, line, "Full stderr: "))
                    {
                        self.stderr.dropLast();
                    } else if (std.mem.eql(u8, line, "[earlier output omitted]")) {
                        self.earlier_omitted = true;
                        self.stderr.dropLast();
                    } else break;
                }
                while (self.stdout.count != 0 and self.stdout.last(0).len == 0) self.stdout.dropLast();
                const tail = if (self.stderr.total != 0) &self.stderr else &self.stdout;
                const shown = @min(tail.count, excerpt_lines);
                var shortened = self.earlier_omitted or tail.total > shown;
                for (0..shown) |index| {
                    const back = shown - 1 - index;
                    shortened = shortened or tail.shortened[(tail.total - 1 - back) % tail.lines.len];
                    try self.escaped.feed(if (self.emitted) "\n  " else "  ");
                    try self.escaped.feed(tail.last(back));
                    self.emitted = true;
                }
                if (shortened) {
                    try self.escaped.feed(if (self.emitted) "\n  " else "  ");
                    try self.escaped.feed("/details for full output.");
                    self.emitted = true;
                }
            }
            try self.escaped.finish();
        }
    };
}

test "tool summary hides only complete routine metadata and retains warnings" {
    const Sink = struct {
        bytes: [2048]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const retirement = "Process retirement confirmed: the child was reaped and the original process group was observed absent. macOS group signaling returned EPERM, which can mean no live targets or permission denial.";
    const warning = "Process-group signaling reported a failure.";
    const incomplete = "Capture may be incomplete because writers outlived process-group termination.";
    const capture_failure = "Capture failure: read; output may be incomplete.";
    const cases = .{
        .{ .succeeded, "Bash succeeded. Exit code: 0.\n" ++ retirement ++ "\nstdout tail:\nhidden", "", "" },
        .{ .succeeded, retirement, "", "" },
        .{ .succeeded, "Bash succeeded. Exit code: 0.\n" ++ incomplete ++ "\n" ++ retirement ++ "\n" ++ warning ++ "\nstderr tail:\nhidden", "  " ++ incomplete ++ "\n  " ++ warning, "" },
        .{ .failed, "Bash failed. Exit code: 7.\n" ++ retirement ++ "\n" ++ capture_failure, "  " ++ capture_failure, "7" },
        .{ .timed_out, "Bash timed_out. Signal: 15.\n" ++ retirement ++ "\n" ++ warning, "  Signal: 15.\n  " ++ warning, "" },
        .{ .cancelled, "Bash cancelled. Signal: 15.\n" ++ retirement, "  Signal: 15.", "" },
        .{ .indeterminate, "Bash indeterminate. Unknown process status: 0.\n" ++ warning, "  Unknown process status: 0.\n  " ++ warning, "" },
        .{ .failed, "Bash succeeded. Exit code: 0. Additional warning.", "  Bash succeeded. Exit code: 0. Additional warning.", "" },
        .{ .succeeded, "Bash failed. Exit code: 7.", "  Bash failed. Exit code: 7.", "" },
        .{ .succeeded, retirement ++ " Additional warning.", "  " ++ retirement ++ " Additional warning.", "" },
        .{ .succeeded, "Process retirement unconfirmed.\n" ++ warning, "  Process retirement unconfirmed.\n  " ++ warning, "" },
        .{ .succeeded, "Bash succeeded. Exit code: 0. Additional warning.", "  Bash succeeded. Exit code: 0. Additional warning.", "" },
        .{ .succeeded, retirement ++ @as([256]u8, @splat('x')) ++ "\n" ++ warning, "  " ++ (retirement ++ @as([256]u8, @splat('x')))[0..256] ++ " [summary shortened; /details]\n  " ++ warning, "" },
        .{ .succeeded, "stdout tail: unavailable\n" ++ warning, "  stdout tail: unavailable\n  " ++ warning, "" },
        // Failures show the last stderr lines, else stdout, without the trailer.
        .{ .failed, "Bash failed. Exit code: 127.\nstdout tail:\n\nstderr tail:\nbash: line 1: rui: command not found\n\nFull stdout: /s/o\nFull stderr: /s/e\n", "  bash: line 1: rui: command not found", "127" },
        .{ .failed, "Bash failed. Exit code: 1.\nstdout tail:\nusage: x\nhelp\n\nstderr tail:\n\nFull output was not retained.\n", "  usage: x\n  help", "1" },
        .{ .failed, "Bash failed. Exit code: 2.\nstdout tail:\n\nstderr tail:\none\ntwo\nthree\nfour\n\n[earlier output omitted]\n\nFull output was not retained.\n", "  two\n  three\n  four\n  /details for full output.", "2" },
        .{ .failed, "Bash failed. Exit code: 3.\nstdout tail:\n\nstderr tail:\nonly\n\n[earlier output omitted]\n", "  only\n  /details for full output.", "3" },
        .{ .succeeded, "Bash succeeded. Exit code: 0.\nstdout tail:\nhidden\n\nstderr tail:\nalso hidden\n", "", "" },
        .{ .failed, "Bash failed. Exit code: 4.\nstdout tail:\n\nstderr tail:\n\x1b[2Jcontrol\n", "  \\x1b[2Jcontrol", "4" },
    };
    inline for (cases) |case| {
        for (0..case[1].len + 1) |split| {
            var sink: Sink = .{};
            const presentation: protocol.ToolPresentation = .{ .description = null, .code = case[0], .publication_position = null };
            var summary: Summary(*Sink) = .{ .presentation = presentation, .code = case[0], .colour = false, .escaped = .{ .sink = &sink, .text = .{ .mode = .multiline } } };
            try summary.feed(case[1][0..split]);
            try summary.feed(case[1][split..]);
            try summary.finish();
            // A failed exit status joins the heading instead of a detail row.
            var heading: Sink = .{};
            try toolHeadingWith(presentation, &heading, false, true, case[3]);
            try std.testing.expectEqualStrings(heading.bytes[0..heading.length], sink.bytes[0..heading.length]);
            try std.testing.expectEqualStrings(case[2], sink.bytes[heading.length..sink.length]);
        }
    }
}

fn workEnded(sink: anytype, code: []const u8) !void {
    try print(sink, "\n! Work ended: {s}. /status for details.\n", .{code});
}

test "an ended Turn says what happened and what to do next where it ended" {
    var buffer: [128]u8 = undefined;
    var out = std.Io.Writer.fixed(&buffer);
    const Sink = struct {
        out: *std.Io.Writer,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            try self.out.writeAll(bytes);
        }
    };
    var sink: Sink = .{ .out = &out };
    try workEnded(&sink, "retry_exhausted");
    // /status only repeats the code, so the line itself carries the next step.
    try std.testing.expectEqualStrings("\n! Work ended: retry_exhausted. Send a message to continue.\n", out.buffered());
}

pub fn render(requests: client.Requests, store: []const u8, session: []const u8, page: *const client.ActivityPage, sink: anytype, colour: bool, compact_tools: *bool) !void {
    const historical = page.facts.direction == .backward;
    for (0..page.facts.count) |index| {
        const item = page.facts.items[if (historical) page.facts.count - index - 1 else index];
        switch (item.value) {
            .admission => |message| {
                if (historical and message.state == .applied) continue;
                compact_tools.* = false;
                if (historical) try sink.feed("\n! Unapplied input:");
                try sink.feed("\n");
                try sink.feed(Style.user.code(colour));
                try sink.feed("›");
                try sink.feed(Style.normal.code(colour));
                try sink.feed(" ");
                try content(requests, store, session, item, message.content, sink);
            },
            .user => |message| {
                if (!historical) continue; // Live Admission already showed it.
                compact_tools.* = false;
                try sink.feed("\n");
                try sink.feed(Style.user.code(colour));
                try sink.feed("›");
                try sink.feed(Style.normal.code(colour));
                try sink.feed(" ");
                try content(requests, store, session, item, message.content, sink);
            },
            .assistant => |reference| {
                compact_tools.* = false;
                try sink.feed("\n  ");
                try content(requests, store, session, item, reference, sink);
            },
            .tool_result => |result| {
                // Keep outcomes and warnings, not routine zero exit codes or
                // output tails. This affects presentation only, never execution,
                // permission or outcome classification; /details stays exact.
                const Source = struct {
                    requests: client.Requests,
                    store: []const u8,
                    session: []const u8,
                    item: protocol.ActivityItem,
                    reference: protocol.ActivityItem.Content,
                    pub fn read(self: @This(), summary: anytype) !void {
                        if (try self.requests.readActivityContent(self.store, self.session, self.item.position, self.item.ordinal, .{ .bytes = self.reference.length, .digest = self.reference.digest }, summary)) |read_failure| return self.requests.failRead(read_failure);
                    }
                };
                try toolResult(result.presentation, Source{ .requests = requests, .store = store, .session = session, .item = item, .reference = result.content }, sink, colour, compact_tools);
            },
            // Hidden call rows use admission-certified page metadata. Exact
            // proposal and permission inspection authenticate originals instead.
            .call => {},
            .outcome => |outcome| {
                // Successful content aggregates assistant rows, never a second answer.
                if (outcome.code.eql("completed")) continue;
                compact_tools.* = false;
                try workEnded(sink, outcome.code.slice());
            },
            .stop => {
                compact_tools.* = false;
                try sink.feed("\n! Session stopped.\n");
            },
        }
    }
}
