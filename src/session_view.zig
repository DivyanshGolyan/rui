//! Bounded public Activity presentation with one forward-only content pass.
//! A failed stream may leave a visible prefix; the terminal owner must not retry it.
const std = @import("std");
const client = @import("client.zig");
const protocol = @import("protocol.zig");
const Text = @import("TerminalText.zig");
const Renderer = @import("AnswerRenderer.zig");
const tools = @import("tools.zig");

extern fn utf8proc_charwidth(scalar: i32) c_int;
extern fn utf8proc_grapheme_break_stateful(i32, i32, *c_int) c_int;

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

pub fn toolHeading(presentation: protocol.ToolPresentation, sink: anytype, columns: usize, colour: bool, separate: bool) !void {
    const state = toolState(presentation.code);
    if (separate) try sink.feed("\n");
    try sink.feed(state.style.code(colour));
    try sink.feed(state.glyph);
    try sink.feed(Style.normal.code(colour));
    try sink.feed(" ");
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink, .columns = columns };
    var escaped: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .line } };
    try escaped.feed(if (presentation.description) |label| label.slice() else "Tool call");
    try escaped.finish();
    try indented.feed(state.suffix);
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
/// escaped or rendered; only trusted renderer SGR has zero display width.
pub fn Indented(comptime Sink: type) type {
    return struct {
        sink: Sink,
        columns: usize = 0,
        column: usize = 2,
        line_start: bool = false,
        sgr: bool = false,
        scalar: [4]u8 = undefined,
        used: usize = 0,
        prior: ?i32 = null,
        grapheme_state: c_int = 0,
        cluster_width: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) anyerror!void {
            var storage: [4096]u8 = undefined;
            var out = std.Io.Writer.fixed(&storage);
            for (bytes) |byte| {
                if (storage.len - out.end < 8) {
                    try self.sink.feed(out.buffered());
                    out.end = 0;
                }
                if (self.sgr or byte == 0x1b) {
                    if (self.line_start) {
                        try out.writeAll("  ");
                        self.column = 2;
                        self.line_start = false;
                    }
                    self.sgr = byte != 'm';
                    try out.writeByte(byte);
                    continue;
                }
                if (byte == '\n') {
                    try out.writeByte(byte);
                    self.column = 0;
                    self.line_start = true;
                    self.prior = null;
                    self.grapheme_state = 0;
                    continue;
                }
                if (self.columns == 0) {
                    // Cell layout owns geometry in the alternate screen.
                    // Preserve hanging indentation without a second UTF-8,
                    // grapheme or width pass through the same output.
                    if (self.line_start) {
                        try out.writeAll("  ");
                        self.line_start = false;
                    }
                    try out.writeByte(byte);
                    continue;
                }
                self.scalar[self.used] = byte;
                self.used += 1;
                const length = try std.unicode.utf8ByteSequenceLength(self.scalar[0]);
                if (self.used != length) continue;
                const value = try std.unicode.utf8Decode(self.scalar[0..length]);
                const scalar: i32 = @intCast(value);
                const boundary = if (self.prior) |prior| utf8proc_grapheme_break_stateful(prior, scalar, &self.grapheme_state) != 0 else true;
                var width: usize = if (value == '\t') 8 - self.column % 8 else @intCast(@max(0, utf8proc_charwidth(scalar)));
                if (value == 0xfe0f or value == 0x20e3 or value >= 0x1f1e6 and value <= 0x1f1ff) width = @max(width, 2);
                // Reserve a wide cell at each cluster start: a later variation
                // selector may widen it, but never permits a mid-cluster wrap.
                if (boundary and self.columns > 3 and !self.line_start and self.column + @max(width, 2) >= self.columns) {
                    try out.writeByte('\n');
                    self.column = 0;
                    self.line_start = true;
                }
                if (self.line_start) {
                    try out.writeAll("  ");
                    self.column = 2;
                    self.line_start = false;
                }
                if (value == '\t') width = 8 - self.column % 8;
                if (boundary) self.cluster_width = 0;
                try out.writeAll(self.scalar[0..length]);
                self.column += @max(width, self.cluster_width) - self.cluster_width;
                self.cluster_width = @max(width, self.cluster_width);
                self.prior = scalar;
                self.used = 0;
            }
            if (out.end != 0) try self.sink.feed(out.buffered());
        }
        pub fn finish(self: *@This()) !void {
            if (self.used != 0 or self.sgr) return error.IncompleteRenderedText;
        }
    };
}

test "conversation wrapping preserves Unicode clusters across content windows" {
    const Sink = struct {
        bytes: [128]u8 = undefined,
        length: usize = 0,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
            self.length += bytes.len;
        }
    };
    const cases = .{
        .{ "abc👩‍💻de", "  abc👩‍💻\n  de" },
        .{ "abc❤️de", "  abc❤️\n  de" },
        .{ "abc🇺🇸de", "  abc🇺🇸\n  de" },
    };
    inline for (cases) |case| {
        for (0..case[0].len + 1) |split| {
            var sink: Sink = .{};
            var presentation: Indented(*Sink) = .{ .sink = &sink, .columns = 8, .line_start = true };
            try presentation.feed(case[0][0..split]);
            try presentation.feed(case[0][split..]);
            try presentation.finish();
            try std.testing.expectEqualStrings(case[1], sink.bytes[0..sink.length]);
        }
    }
}

pub fn permission(requests: client.Requests, store: []const u8, session: []const u8, action: u64, workspace: []const u8, scratch: std.Io.File, sink: anytype, columns: usize, colour: bool) !void {
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
    try sink.feed("\n");
    try sink.feed(Style.attention.code(colour));
    try sink.feed("? Run Bash:");
    try sink.feed(Style.normal.code(colour));
    try sink.feed("\n  ");
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink, .columns = columns };
    var escaped: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .multiline } };
    if (!try tools.writeBashCommand(&source, &escaped)) return error.InvalidBashArguments;
    try escaped.finish();
    try indented.feed("\nWorkspace: ");
    var location: Escaped(@TypeOf(&indented)) = .{ .sink = &indented, .text = .{ .mode = .line } };
    try location.feed(workspace);
    try location.finish();
    if (arguments.timeout_ms) |timeout| {
        try print(&indented, "\nTime limit: {d} ms", .{timeout});
    } else try indented.feed("\nTime limit: Host default");
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

fn content(requests: client.Requests, store: []const u8, session: []const u8, item: protocol.ActivityItem, reference: protocol.ActivityItem.Content, sink: anytype, columns: usize) !void {
    var indented: Indented(@TypeOf(sink)) = .{ .sink = sink, .columns = columns };
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

fn Summary(comptime Sink: type) type {
    return struct {
        escaped: Escaped(Sink),
        code: protocol.ToolPresentation.Code,
        line: [256]u8 = undefined,
        length: usize = 0,
        emitted: bool = false,
        ended: bool = false,
        omitted: bool = false,
        pub fn feed(self: *@This(), bytes: []const u8) !void {
            for (bytes) |byte| {
                if (self.ended) return;
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
            // Only complete, known informational lines are quiet. Unknown or
            // qualified diagnostics stay visible, even after successful exit.
            // Keep canonical Bash evidence and detailed inspection unchanged.
            const routine = !self.omitted and
                (std.mem.eql(u8, line, "Bash succeeded. Exit code: 0.") or
                    std.mem.eql(u8, line, "Process retirement confirmed: the child was reaped and the original process group was observed absent. macOS group signaling returned EPERM, which can mean no live targets or permission denial."));
            if (!self.omitted and (std.mem.eql(u8, line, "stdout tail:") or std.mem.eql(u8, line, "stderr tail:"))) {
                self.ended = true;
            } else if (line.len != 0 and !routine) {
                var prefix_buffer: [64]u8 = undefined;
                const prefix = switch (self.code) {
                    .failed, .timed_out, .indeterminate, .storage_failed, .spawn_failed, .cancelled, .infrastructure_shutdown => try std.fmt.bufPrint(&prefix_buffer, "Bash {s}. ", .{@tagName(self.code)}),
                    else => "",
                };
                const detail = if (!self.omitted and prefix.len != 0 and std.mem.startsWith(u8, line, prefix)) line[prefix.len..] else line;
                try self.escaped.feed(if (self.emitted) "\n  " else "  ");
                try self.escaped.feed(detail);
                if (self.omitted) try self.escaped.feed(" [summary shortened; /details]");
                self.emitted = true;
            }
            self.length = 0;
            self.omitted = false;
        }
        fn finish(self: *@This()) !void {
            if (self.length != 0) try self.emit();
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
        .{ .succeeded, "Bash succeeded. Exit code: 0.\n" ++ retirement ++ "\nstdout tail:\nhidden", "" },
        .{ .succeeded, retirement, "" },
        .{ .succeeded, "Bash succeeded. Exit code: 0.\n" ++ incomplete ++ "\n" ++ retirement ++ "\n" ++ warning ++ "\nstderr tail:\nhidden", "  " ++ incomplete ++ "\n  " ++ warning },
        .{ .failed, "Bash failed. Exit code: 7.\n" ++ retirement ++ "\n" ++ capture_failure, "  Exit code: 7.\n  " ++ capture_failure },
        .{ .timed_out, "Bash timed_out. Signal: 15.\n" ++ retirement ++ "\n" ++ warning, "  Signal: 15.\n  " ++ warning },
        .{ .cancelled, "Bash cancelled. Signal: 15.\n" ++ retirement, "  Signal: 15." },
        .{ .indeterminate, "Bash indeterminate. Unknown process status: 0.\n" ++ warning, "  Unknown process status: 0.\n  " ++ warning },
        .{ .failed, "Bash succeeded. Exit code: 0. Additional warning.", "  Bash succeeded. Exit code: 0. Additional warning." },
        .{ .succeeded, "Bash failed. Exit code: 7.", "  Bash failed. Exit code: 7." },
        .{ .succeeded, retirement ++ " Additional warning.", "  " ++ retirement ++ " Additional warning." },
        .{ .succeeded, "Process retirement unconfirmed.\n" ++ warning, "  Process retirement unconfirmed.\n  " ++ warning },
        .{ .succeeded, "Bash succeeded. Exit code: 0. Additional warning.", "  Bash succeeded. Exit code: 0. Additional warning." },
        .{ .succeeded, retirement ++ @as([256]u8, @splat('x')) ++ "\n" ++ warning, "  " ++ (retirement ++ @as([256]u8, @splat('x')))[0..256] ++ " [summary shortened; /details]\n  " ++ warning },
        .{ .succeeded, "stdout tail: unavailable\n" ++ warning, "  stdout tail: unavailable\n  " ++ warning },
    };
    inline for (cases) |case| {
        for (0..case[1].len + 1) |split| {
            var sink: Sink = .{};
            var summary: Summary(*Sink) = .{ .code = case[0], .escaped = .{ .sink = &sink, .text = .{ .mode = .multiline } } };
            try summary.feed(case[1][0..split]);
            try summary.feed(case[1][split..]);
            try summary.finish();
            try std.testing.expectEqualStrings(case[2], sink.bytes[0..sink.length]);
        }
    }
}

pub fn render(requests: client.Requests, store: []const u8, session: []const u8, page: *const client.ActivityPage, sink: anytype, columns: usize, colour: bool, compact_tools: *bool) !void {
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
                try content(requests, store, session, item, message.content, sink, columns);
            },
            .user => |message| {
                if (!historical) continue; // Live Admission already showed it.
                compact_tools.* = false;
                try sink.feed("\n");
                try sink.feed(Style.user.code(colour));
                try sink.feed("›");
                try sink.feed(Style.normal.code(colour));
                try sink.feed(" ");
                try content(requests, store, session, item, message.content, sink, columns);
            },
            .assistant => |reference| {
                compact_tools.* = false;
                try sink.feed("\n  ");
                try content(requests, store, session, item, reference, sink, columns);
            },
            .tool_result => |result| {
                // Keep outcomes and warnings, not routine zero exit codes or
                // output tails. This affects presentation only, never execution,
                // permission or outcome classification; /details stays exact.
                const succeeded = result.presentation.code == .succeeded;
                try toolHeading(result.presentation, sink, columns, colour, !compact_tools.* or !succeeded);
                const failed = toolState(result.presentation.code).style == .failure;
                var summary: Summary(@TypeOf(sink)) = .{
                    .escaped = .{ .sink = sink, .text = .{ .mode = .multiline } },
                    .code = result.presentation.code,
                    .ended = switch (result.presentation.code) {
                        .denied, .unknown_tool, .invalid_arguments, .tool_unavailable => true,
                        else => false,
                    },
                };
                const reference = result.content;
                if (try requests.readActivityContent(store, session, item.position, item.ordinal, .{ .bytes = reference.length, .digest = reference.digest }, &summary)) |failure| return requests.failRead(failure);
                try summary.finish();
                if (failed) try sink.feed("\n  /details for output.");
                if (summary.emitted or failed) try sink.feed("\n");
                compact_tools.* = succeeded and !summary.emitted;
            },
            // Hidden call rows use admission-certified page metadata. Exact
            // proposal and permission inspection authenticate originals instead.
            .call => {},
            .outcome => |outcome| {
                // Successful content aggregates assistant rows, never a second answer.
                if (outcome.code.eql("completed")) continue;
                compact_tools.* = false;
                try print(sink, "\n! Work ended: {s}. /status for details.\n", .{outcome.code.slice()});
            },
            .stop => {
                compact_tools.* = false;
                try sink.feed("\n! Session stopped.\n");
            },
        }
    }
}
