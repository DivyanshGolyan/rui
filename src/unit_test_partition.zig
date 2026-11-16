const std = @import("std");

pub const Root = enum { native, store };
pub const roots = std.enums.values(Root);

pub fn owner(name: []const u8) Root {
    return if (std.mem.startsWith(u8, name, "store.")) .store else .native;
}
