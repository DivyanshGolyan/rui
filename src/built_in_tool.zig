const std = @import("std");

pub const BuiltInTool = enum { bash, find_tools, message_agent, read_action, read_image, read_transcript, skill, start_agent, stop_action, watch_github_pr, web_search };

pub const Selection = std.enums.EnumSet(BuiltInTool);
