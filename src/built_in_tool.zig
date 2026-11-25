const std = @import("std");

pub const BuiltInTool = enum { bash, find_tools, message_agent, read_image, read_transcript, skill, start_agent, stop_action, watch_github_pr, web_search };

pub const Selection = std.enums.EnumSet(BuiltInTool);

/// How a built-in tool is spelled to a person. Only `web_search` reads as two words.
pub fn shown(tool: BuiltInTool) []const u8 {
    return switch (tool) {
        .web_search => "web search",
        else => @tagName(tool),
    };
}

/// `shown` for a tool name that may belong to an MCP server, which is left as it is.
pub fn shownName(name: []const u8) []const u8 {
    const tool = std.meta.stringToEnum(BuiltInTool, name) orelse return name;
    return shown(tool);
}

test "SUI-168 a built-in tool is shown by its tag except web search, and any other name is shown unchanged" {
    for (std.enums.values(BuiltInTool)) |tool| {
        const expected = if (tool == .web_search) "web search" else @tagName(tool);
        try std.testing.expectEqualStrings(expected, shown(tool));
        try std.testing.expectEqualStrings(expected, shownName(@tagName(tool)));
    }
    for ([_][]const u8{ "mcp__x", "web search", "lookup", "none", "" }) |name| {
        try std.testing.expectEqualStrings(name, shownName(name));
    }
}
