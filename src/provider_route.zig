//! How a Host serves each provider.
const std = @import("std");
const Provider = @import("provider_name.zig").Provider;

/// How a Host serves a provider: not at all, at a development endpoint
/// that takes no credential, or at its own endpoint with its credential:
/// a ChatGPT device sign-in to the Codex backend, a key, or a ChatGPT plan
/// sign-in to OpenAI's API, which the plan pays for.
pub const Route = enum { unserved, endpoint, chatgpt_device, key_file, chatgpt_plan };

/// Each provider's Route, as `host_info` reports it.
pub const Routes = std.enums.EnumFieldStruct(Provider, Route, null);

/// Every provider on `route`.
pub fn all(route: Route) Routes {
    var routes: Routes = undefined;
    inline for (@typeInfo(Provider).@"enum".field_names) |name| @field(routes, name) = route;
    return routes;
}

pub fn of(routes: Routes, provider: Provider) Route {
    return switch (provider) {
        inline else => |tag| blk: {
            const name = @tagName(tag);
            break :blk @field(routes, name);
        },
    };
}

/// Whether a Host with these Routes makes model requests for any provider.
pub fn servesModel(routes: Routes) bool {
    inline for (@typeInfo(Provider).@"enum".field_names) |name| if (@field(routes, name) != .unserved) return true;
    return false;
}
