const std = @import("std");
const Provider = @import("provider_name.zig").Provider;

pub const Route = enum { unserved, endpoint, chatgpt_device, key_file, chatgpt_plan };

pub const Routes = std.enums.EnumFieldStruct(Provider, Route, null);

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

pub fn servesModel(routes: Routes) bool {
    inline for (@typeInfo(Provider).@"enum".field_names) |name| if (@field(routes, name) != .unserved) return true;
    return false;
}
