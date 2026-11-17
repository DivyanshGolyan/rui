const std = @import("std");

pub const BuiltInTool = enum { bash, find_tools, message_agent, read_action, read_transcript, skill, start_agent, stop_action, web_search };

pub const Selection = std.enums.EnumSet(BuiltInTool);
