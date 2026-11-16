const std = @import("std");

pub const EngineName = enum { sqlite, mysql, postgres };

pub fn parse(list: []const u8) error{UnknownRequiredEngine}!std.EnumSet(EngineName) {
    var names: std.EnumSet(EngineName) = .empty;
    if (list.len == 0) return names;
    var tokens = std.mem.splitScalar(u8, list, ',');
    while (tokens.next()) |token| names.insert(std.meta.stringToEnum(EngineName, token) orelse return error.UnknownRequiredEngine);
    return names;
}

pub fn fromEnviron(environ: *const std.process.Environ.Map) error{UnknownRequiredEngine}!std.EnumSet(EngineName) {
    return parse(environ.get("RUI_TEST_REQUIRE_ENGINES") orelse "");
}
