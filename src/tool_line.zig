//! The words of a tool call ("Message abc123", "Search “q”", "Read an image"): the one owner of call wording.
//! Pure. `call_classification` decides which `Call` a set of facts is; this file decides what it says, and `of` derives a
//! saved call's line at read from what the Store holds: the tool's name, the label the model gave, the Session the call named.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const HostedAction = @import("hosted_action.zig").HostedAction;
const saved_label = @import("saved_label.zig");
const session_id = @import("session_id.zig");
const tool_presentation = @import("tool_presentation.zig");
const tool_proposal = @import("tool_proposal.zig");
const utf8_validation = @import("utf8_validation.zig");

/// The most bytes one call line may take: one line of words, whoever draws it.
pub const max_bytes = tool_presentation.max_description_bytes;
pub const Description = Bounded(max_bytes);

/// One variant per built-in tool; `call_classification` checks at compile time that none is missing.
pub const Call = union(enum) {
    /// The label the model gave the command, as one tidy line.
    bash: []const u8,
    find_tools,
    /// The id of the Session the message is for.
    message_agent: []const u8,
    read_image,
    read_transcript: ?Bounded(session_id.max_reference_bytes),
    skill,
    start_agent,
    stop_action,
    watch_github_pr,
    web_search: WebSearchCall,
};

pub const WebSearchCall = struct {
    action: HostedAction,
    target: []const u8 = "",
    pattern: []const u8 = "",

    pub const excerpt_bytes = 2 * max_bytes;
};

/// What the Store holds of one saved call: the facts its line is derived from, and nothing of the line itself.
pub const Facts = struct {
    /// The tool's saved name, at most `tool_name.max_bytes`, read inline.
    name: []const u8,
    /// A call no tool served (`unknown_tool`, `invalid_arguments`) has no line.
    rejection: ?tool_proposal.Rejection = null,
    /// What the model said about the call (a Bash or MCP `description` argument), as saved.
    label: ?[]const u8 = null,
    /// The Session a `message_agent` or `read_transcript` call named.
    subject: ?[]const u8 = null,
    /// That Session's label now, so a rename shows on every row that names it.
    subject_label: ?Bounded(saved_label.max_label_bytes) = null,
};

/// The line of a saved call, or null for a call no tool served. A built-in tool says its own words; Bash says its label,
/// or the fallback words when it has none; any other tool (an MCP or app tool) says its label, or its own name.
/// Total over any saved text: a label is read through `saved_label`. A subject that is not a Session reference is an error.
pub fn of(facts: Facts) tool_presentation.Line.Error!?tool_presentation.Line {
    if (facts.rejection != null) return null;
    const label = facts.label orelse "";
    const words = saved_label.callWords(label);
    const tool = std.meta.stringToEnum(std.meta.Tag(Call), facts.name) orelse .web_search;
    const call: Call = switch (tool) {
        .bash => .{ .bash = words.slice() },
        .find_tools => .find_tools,
        .message_agent => .{ .message_agent = facts.subject orelse "" },
        .read_image => .read_image,
        .read_transcript => .{ .read_transcript = if (facts.subject) |id| Bounded(session_id.max_reference_bytes).from(id) catch return error.InvalidLine else null },
        .skill => .skill,
        .start_agent => .start_agent,
        .stop_action => .stop_action,
        .watch_github_pr => .watch_github_pr,
        // Not a built-in tool's name (a hosted search is never a saved call): an MCP or app tool.
        .web_search => return tool_presentation.Line.ofSaved(if (saved_label.readWords(max_bytes, label) != null) label else facts.name),
    };
    var line = try lineOf(call);
    if (line.link != null) if (saved_label.labelWords(facts.subject_label)) |peer| try line.setLabel(peer.slice());
    return line;
}

fn lineOf(call: Call) tool_presentation.Line.Error!tool_presentation.Line {
    const Line = tool_presentation.Line;
    return switch (call) {
        .bash => |label| Line.plain(label),
        .message_agent => |id| if (id.len == 0) Line.plain("Message an agent") else Line.linked("Message ", id, ""),
        .find_tools => Line.plain("Find tools"),
        .read_image => Line.plain("Read an image"),
        .read_transcript => |id| if (id) |target| Line.linked("Read ", target.slice(), "'s transcript") else Line.plain("Read own transcript"),
        .skill => Line.plain("Use skills"),
        .stop_action => Line.plain("Stop an Action"),
        .start_agent => Line.plain("Start an agent"),
        .watch_github_pr => Line.plain("Watch a GitHub pull request"),
        .web_search => |search| Line.plain(describeWebSearch(search).slice()),
    };
}

/// A hosted web search's line from its stored action, read at display time. `target` and `pattern` are the leading bytes
/// of the first target and of the pattern (at most `WebSearchCall.excerpt_bytes` of each is looked at), never the stored text.
pub fn ofHosted(action: HostedAction, target: []const u8, pattern: []const u8) Description {
    return describeWebSearch(.{ .action = action, .target = target, .pattern = pattern });
}

fn describeWebSearch(call: WebSearchCall) Description {
    var target_text: Excerpt = .{};
    var pattern_text: Excerpt = .{};
    target_text.read(call.target);
    pattern_text.read(call.pattern);
    var page = target_text.slice();
    if (call.action == .open_page or call.action == .find_in_page) {
        for ([_][]const u8{ "https://", "http://" }) |scheme| if (std.ascii.startsWithIgnoreCase(page, scheme)) {
            page = page[scheme.len..];
            break;
        };
        if (std.ascii.startsWithIgnoreCase(page, "www.")) page = page[4..];
    }
    const quoted = target_text.slice();
    const found = pattern_text.slice();
    var out: Description = .{};
    switch (call.action) {
        .search => if (quoted.len != 0) compose(&out, &.{ "Search “", "”" }, &.{quoted}) else compose(&out, &.{"Search the web"}, &.{}),
        .open_page => if (page.len != 0) compose(&out, &.{ "Open ", "" }, &.{page}) else compose(&out, &.{"Open a page"}, &.{}),
        .find_in_page => if (found.len != 0 and page.len != 0)
            compose(&out, &.{ "Find “", "” in ", "" }, &.{ found, page })
        else if (found.len != 0)
            compose(&out, &.{ "Find “", "”" }, &.{found})
        else if (page.len != 0)
            compose(&out, &.{ "Find in ", "" }, &.{page})
        else
            compose(&out, &.{"Find in a page"}, &.{}),
        .none => compose(&out, &.{"Search the web"}, &.{}),
    }
    return out;
}

const Excerpt = struct {
    bytes: [WebSearchCall.excerpt_bytes]u8 = undefined,
    len: usize = 0,

    fn read(self: *Excerpt, bytes: []const u8) void {
        const raw = bytes[0..@min(bytes.len, WebSearchCall.excerpt_bytes)];
        const valid = utf8_validation.wholePrefix(raw) orelse return;
        var scalars = std.unicode.Utf8View.initUnchecked(valid).iterator();
        var space = false;
        while (scalars.nextCodepointSlice()) |encoded| {
            const scalar = std.unicode.utf8Decode(encoded) catch unreachable;
            const blank = scalar < 0x20 or scalar == 0x7f or switch (scalar) {
                ' ', 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
                else => false,
            };
            if (blank) {
                space = self.len != 0;
                continue;
            }
            if (space) self.append(" ");
            space = false;
            self.append(encoded);
        }
    }

    fn append(self: *Excerpt, encoded: []const u8) void {
        @memcpy(self.bytes[self.len..][0..encoded.len], encoded);
        self.len += encoded.len;
    }

    fn slice(self: *const Excerpt) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn compose(out: *Description, comptime literals: []const []const u8, values: []const []const u8) void {
    std.debug.assert(literals.len == values.len + 1 or (values.len == 0 and literals.len == 1));
    comptime var fixed: usize = 0;
    inline for (literals) |literal| fixed += literal.len;
    const room = out.bytes.len - fixed;
    var widths: [2]usize = .{ 0, 0 };
    switch (values.len) {
        0 => {},
        1 => widths[0] = @min(values[0].len, room),
        2 => {
            widths[1] = @min(values[1].len, @max(room / 2, room -| values[0].len));
            widths[0] = @min(values[0].len, room - widths[1]);
        },
        else => unreachable,
    }
    var writer = std.Io.Writer.fixed(&out.bytes);
    inline for (literals, 0..) |literal, index| {
        writer.writeAll(literal) catch unreachable;
        if (index < values.len) writeCut(&writer, values[index], widths[@min(index, widths.len - 1)]);
    }
    out.len = writer.end;
}

fn writeCut(writer: *std.Io.Writer, text: []const u8, width: usize) void {
    if (text.len <= width) return writer.writeAll(text) catch unreachable;
    const ellipsis = "…";
    var end = utf8_validation.scalarStart(text, width -| ellipsis.len);
    while (end > 0 and text[end - 1] == ' ') end -= 1;
    writer.writeAll(text[0..end]) catch unreachable;
    writer.writeAll(ellipsis) catch unreachable;
}

test "TPR-4 a web search call's description says what it did, on one line, within the bound" {
    @setEvalBranchQuota(10_000);
    const repeat = struct {
        fn of(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
            comptime {
                var result: [text.len * count]u8 = undefined;
                for (0..count) |index| @memcpy(result[index * text.len ..][0..text.len], text);
                const final = result;
                return &final;
            }
        }
    }.of;
    const Case = struct { action: HostedAction, target: ?[]const u8 = null, pattern: ?[]const u8 = null, expected: []const u8 };
    const long = (comptime repeat("a", 220));
    for ([_]Case{
        .{ .action = .search, .target = "zig 0.17 release notes", .expected = "Search “zig 0.17 release notes”" },
        .{ .action = .search, .target = " \n\t ", .expected = "Search the web" },
        .{ .action = .search, .expected = "Search the web" },
        .{ .action = .search, .target = (comptime repeat("a", 183)) ++ " bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .expected = "Search “" ++ (comptime repeat("a", 183)) ++ "…”" },
        .{ .action = .none, .target = "ignored", .expected = "Search the web" },
        .{ .action = .search, .target = "  two\r\nlines\u{2028}here  ", .expected = "Search “two lines here”" },
        .{ .action = .open_page, .target = "https://www.ziglang.org/download/", .expected = "Open ziglang.org/download/" },
        .{ .action = .open_page, .target = "HTTP://example.com", .expected = "Open example.com" },
        .{ .action = .open_page, .expected = "Open a page" },
        .{ .action = .find_in_page, .target = "https://ziglang.org/notes", .pattern = "Io.Writer", .expected = "Find “Io.Writer” in ziglang.org/notes" },
        .{ .action = .find_in_page, .pattern = "Io.Writer", .expected = "Find “Io.Writer”" },
        .{ .action = .find_in_page, .target = "ziglang.org", .expected = "Find in ziglang.org" },
        .{ .action = .find_in_page, .expected = "Find in a page" },
        .{ .action = .search, .target = long, .expected = "Search “" ++ (comptime repeat("a", 184)) ++ "…”" },
        .{ .action = .search, .target = "a" ++ (comptime repeat("é", 110)), .expected = "Search “a" ++ (comptime repeat("é", 91)) ++ "…”" },
        .{ .action = .find_in_page, .target = long, .pattern = long, .expected = "Find “" ++ (comptime repeat("a", 90)) ++ "…” in " ++ (comptime repeat("a", 89)) ++ "…" },
        .{ .action = .find_in_page, .target = long, .pattern = "x", .expected = "Find “x” in " ++ (comptime repeat("a", 181)) ++ "…" },
        .{ .action = .search, .target = "\xff\xfe\xfd\xfc", .expected = "Search the web" },
        .{ .action = .search, .target = "q\xe2\x82", .expected = "Search “q”" },
    }) |case| {
        const description = describeWebSearch(.{ .action = case.action, .target = case.target orelse "", .pattern = case.pattern orelse "" });
        try std.testing.expectEqualStrings(case.expected, description.slice());
        try std.testing.expect(description.slice().len <= max_bytes);
    }
}

test "TPR-4 a saved call's line is derived from its tool, label and subject, and a call no tool served has none" {
    var peer = Bounded(saved_label.max_label_bytes){};
    try peer.set("Review the WAL");
    const long_label: [max_bytes]u8 = @splat('x');
    const long_subject: [session_id.max_reference_bytes + 1]u8 = @splat('x');
    const Case = struct { facts: Facts, plain: ?[]const u8, peer: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .facts = .{ .name = "bash", .label = "Run parser tests" }, .plain = "Run parser tests" },
        .{ .facts = .{ .name = "bash", .label = "  Run\nparser   tests " }, .plain = "Run parser tests" },
        .{ .facts = .{ .name = "bash", .label = &long_label }, .plain = &long_label },
        .{ .facts = .{ .name = "bash" }, .plain = saved_label.fallback_words },
        .{ .facts = .{ .name = "bash", .label = " \n" }, .plain = saved_label.fallback_words },
        .{ .facts = .{ .name = "find_tools" }, .plain = "Find tools" },
        .{ .facts = .{ .name = "find_tools", .label = "ignored", .subject = "abc123" }, .plain = "Find tools" },
        .{ .facts = .{ .name = "message_agent", .subject = "abc123" }, .plain = "Message abc123", .peer = "abc123" },
        .{ .facts = .{ .name = "message_agent", .subject = "abc123", .subject_label = peer }, .plain = "Message Review the WAL", .peer = "abc123" },
        .{ .facts = .{ .name = "message_agent" }, .plain = "Message an agent" },
        .{ .facts = .{ .name = "read_image" }, .plain = "Read an image" },
        .{ .facts = .{ .name = "read_transcript" }, .plain = "Read own transcript" },
        .{ .facts = .{ .name = "read_transcript", .subject = "zzzzzz" }, .plain = "Read zzzzzz's transcript", .peer = "zzzzzz" },
        .{ .facts = .{ .name = "read_transcript", .subject = "zzzzzz", .subject_label = peer }, .plain = "Read Review the WAL's transcript", .peer = "zzzzzz" },
        .{ .facts = .{ .name = "skill" }, .plain = "Use skills" },
        .{ .facts = .{ .name = "stop_action" }, .plain = "Stop an Action" },
        .{ .facts = .{ .name = "start_agent" }, .plain = "Start an agent" },
        .{ .facts = .{ .name = "watch_github_pr" }, .plain = "Watch a GitHub pull request" },
        // Any other tool is an MCP or app tool: its label when the model gave one, else its own name.
        .{ .facts = .{ .name = "find_docs", .label = "Find the install page" }, .plain = "Find the install page" },
        .{ .facts = .{ .name = "mcp__docs__find" }, .plain = "mcp__docs__find" },
        .{ .facts = .{ .name = "mcp__docs__find", .label = "  " }, .plain = "mcp__docs__find" },
        // A call no tool served has no line, whatever else was saved.
        .{ .facts = .{ .name = "bash", .label = "Run", .rejection = .unknown_tool }, .plain = null },
        .{ .facts = .{ .name = "message_agent", .rejection = .invalid_arguments }, .plain = null },
        .{ .facts = .{ .name = "no_such_tool", .rejection = .unknown_tool }, .plain = null },
    };
    for (cases) |case| {
        const line = try of(case.facts) orelse {
            try std.testing.expect(case.plain == null);
            continue;
        };
        try std.testing.expect(line.valid());
        var out: [2 * max_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out);
        try line.writePlain(&writer);
        try std.testing.expectEqualStrings(case.plain.?, writer.buffered());
        try std.testing.expectEqual(case.peer != null, line.link != null);
        if (case.peer) |id| try std.testing.expectEqualStrings(id, line.link.?.peer.session.slice());
    }
    try std.testing.expectError(error.InvalidLine, of(.{ .name = "message_agent", .subject = "bad\nid" }));
    try std.testing.expectError(error.InvalidLine, of(.{ .name = "read_transcript", .subject = &long_subject }));
}
