//! Fixtures Store conformance tests.
const std = @import("std");
const store_testing = @import("../testing.zig");

test "RUI_TEST_REQUIRE_ENGINES names engines by exact token" {
    const Name = store_testing.EngineName;
    try std.testing.expectEqual(0, (try store_testing.parseRequiredEngines("")).count());
    const listed = try store_testing.parseRequiredEngines("postgres,mysql");
    try std.testing.expect(listed.contains(Name.mysql) and listed.contains(Name.postgres) and !listed.contains(Name.sqlite));
    try std.testing.expect((try store_testing.parseRequiredEngines("sqlite")).contains(Name.sqlite));
    for ([_][]const u8{ "mysqlx", "my", " mysql", "mysql,", ",sqlite", "postgres,,mysql", "MySQL", "oracle" }) |list| {
        try std.testing.expectError(error.UnknownRequiredEngine, store_testing.parseRequiredEngines(list));
    }
}

test "a required engine these tests do not build fails them" {
    const Name = store_testing.EngineName;
    try std.testing.expectEqual(null, store_testing.unbuiltEngine(.empty, .empty));
    try std.testing.expectEqual(null, store_testing.unbuiltEngine(.initMany(&.{ Name.sqlite, Name.mysql }), .empty));
    try std.testing.expectEqual(Name.postgres, store_testing.unbuiltEngine(.initMany(&.{ Name.sqlite, Name.postgres }), .initOne(Name.mysql)));
    // CI's live shards list both servers; each has a test of its own here.
    try std.testing.expectEqual(null, store_testing.unbuiltEngine(.initMany(&.{ Name.sqlite, Name.mysql, Name.postgres }), store_testing.checked_elsewhere));
}

test "a fixture's SQL is portable Rui SQL and names no SQLite mechanism" {
    inline for (store_testing.fixture_text_cases) |case| {
        const message = comptime store_testing.fixtureTextError(case.text);
        if ((message != null) != case.refused) {
            std.debug.print("fixtureTextError({s}) = {?s}\n", .{ case.text, message });
            return error.FixtureVerdictChanged;
        }
    }
    try std.testing.expectEqualStrings("fixture: 'pragma' is a SQLite mechanism; write the test in sqlite_tests.zig", comptime store_testing.fixtureTextError("DELETE FROM turn; pragma ignore_check_constraints=ON").?);
    try std.testing.expectEqualStrings("rsql: 'INSERT OR' is not portable; read in an earlier round, then guard the write", comptime store_testing.fixtureTextError("INSERT OR IGNORE INTO turn VALUES(1)").?);
}
