//! The tools the Host offers, by name. A leaf, so functional cores can
//! name a tool too.
const std = @import("std");

/// The tools the Host offers, in their names' byte order: `bash` runs locally as
/// Actions; `message_agent` is the core's own, run as a core command (D24);
/// `web_search` is hosted, run by the provider inside a response.
pub const BuiltInTool = enum { bash, message_agent, web_search };

/// A Session's built-in tools, as reports and list rows carry them.
pub const Selection = std.enums.EnumSet(BuiltInTool);
