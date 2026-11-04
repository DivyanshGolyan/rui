//! `RUI_TEST_REQUIRE_ENGINES`: the engines a test run must reach, each by
//! name. The Store's conformance tests and the Postgres wire tests both read
//! it, so the one parser lives here, where wire tests may import it.

const std = @import("std");

/// The names `RUI_TEST_REQUIRE_ENGINES` may list.
pub const EngineName = enum { sqlite, mysql, postgres };

/// `list`, comma-separated, as a set of names. Each token must equal one
/// name of `EngineName` exactly, so "mysqlx", " mysql" and an empty token
/// are `UnknownRequiredEngine`. An empty `list` names none.
pub fn parse(list: []const u8) error{UnknownRequiredEngine}!std.EnumSet(EngineName) {
    var names: std.EnumSet(EngineName) = .empty;
    if (list.len == 0) return names;
    var tokens = std.mem.splitScalar(u8, list, ',');
    while (tokens.next()) |token| names.insert(std.meta.stringToEnum(EngineName, token) orelse return error.UnknownRequiredEngine);
    return names;
}

/// The names `environ` lists; none when it does not set the variable.
pub fn fromEnviron(environ: *const std.process.Environ.Map) error{UnknownRequiredEngine}!std.EnumSet(EngineName) {
    return parse(environ.get("RUI_TEST_REQUIRE_ENGINES") orelse "");
}
