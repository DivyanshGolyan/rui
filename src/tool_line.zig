//! The words of a tool call ("Message abc123", "Search “q”", "Read an image"): the one owner of call wording.
//! Pure. `call_classification` decides which `Call` a set of facts is; this file decides what it says.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const HostedAction = @import("hosted_action.zig").HostedAction;
const session_id = @import("session_id.zig");
const utf8_validation = @import("utf8_validation.zig");

/// The most bytes one call line may take: one line of words, whoever draws it. This file owns the limit and
/// `tool_presentation` and the MCP argument shape name it, so this file imports none of them and stays a leaf.
pub const max_bytes = 200;
pub const Description = Bounded(max_bytes);

/// One variant per built-in tool; `call_classification` checks at compile time that none is missing.
pub const Call = union(enum) {
    /// The label the model gave the command.
    bash: []const u8,
    find_tools,
    /// The id of the Session the message is for.
    message_agent: []const u8,
    read_image,
    read_transcript: ?Bounded(session_id.bytes),
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

pub fn describe(call: Call) Description {
    const out: Description = switch (call) {
        .bash => |label| blk: {
            var out: Description = .{};
            out.set(label) catch unreachable;
            break :blk out;
        },
        .message_agent => |id| blk: {
            var out: Description = .{};
            compose(&out, &.{ "Message ", "" }, &.{id});
            break :blk out;
        },
        .find_tools => blk: {
            var out: Description = .{};
            out.set("Find tools") catch unreachable;
            break :blk out;
        },
        .read_image => blk: {
            var out: Description = .{};
            out.set("Read an image") catch unreachable;
            break :blk out;
        },
        .read_transcript => |id| blk: {
            var out: Description = .{};
            if (id) |target| compose(&out, &.{ "Read ", "'s transcript" }, &.{target.slice()}) else compose(&out, &.{"Read own transcript"}, &.{});
            break :blk out;
        },
        .skill => blk: {
            var out: Description = .{};
            out.set("Use skills") catch unreachable;
            break :blk out;
        },
        .stop_action => blk: {
            var out: Description = .{};
            out.set("Stop an Action") catch unreachable;
            break :blk out;
        },
        .start_agent => blk: {
            var out: Description = .{};
            out.set("Start an agent") catch unreachable;
            break :blk out;
        },
        .watch_github_pr => blk: {
            var out: Description = .{};
            out.set("Watch a GitHub pull request") catch unreachable;
            break :blk out;
        },
        .web_search => |search| describeWebSearch(search),
    };
    return out;
}

/// A hosted web search's line from its stored action, read at display time. `target` and `pattern` are the leading bytes
/// of the first target and of the pattern (at most `WebSearchCall.excerpt_bytes` of each is looked at), never the stored text.
pub fn ofHosted(action: HostedAction, target: []const u8, pattern: []const u8) Description {
    return describe(.{ .web_search = .{ .action = action, .target = target, .pattern = pattern } });
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
        const description = describe(.{ .web_search = .{ .action = case.action, .target = case.target orelse "", .pattern = case.pattern orelse "" } });
        try std.testing.expectEqualStrings(case.expected, description.slice());
        try std.testing.expect(description.slice().len <= max_bytes);
    }
}

test "TPR-4 a Bash call is described by the description its arguments carry" {
    try std.testing.expectEqualStrings("Run parser tests", describe(.{ .bash = "Run parser tests" }).slice());
}

test "TPR-4 every tool call has fixed words, or the words of what it names" {
    const id: []const u8 = "abc123";
    const own: ?Bounded(session_id.bytes) = null;
    var other: Bounded(session_id.bytes) = .{};
    try other.set("zzzzzz");
    const cases = [_]struct { call: Call, expected: []const u8 }{
        .{ .call = .{ .bash = "Run parser tests" }, .expected = "Run parser tests" },
        .{ .call = .{ .message_agent = id }, .expected = "Message abc123" },
        .{ .call = .find_tools, .expected = "Find tools" },
        .{ .call = .read_image, .expected = "Read an image" },
        .{ .call = .{ .read_transcript = own }, .expected = "Read own transcript" },
        .{ .call = .{ .read_transcript = other }, .expected = "Read zzzzzz's transcript" },
        .{ .call = .skill, .expected = "Use skills" },
        .{ .call = .stop_action, .expected = "Stop an Action" },
        .{ .call = .start_agent, .expected = "Start an agent" },
        .{ .call = .watch_github_pr, .expected = "Watch a GitHub pull request" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, describe(case.call).slice());
}
