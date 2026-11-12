//! The opaque base and effective floor a request actually replays.
const std = @import("std");
const Kind = @import("output_item.zig").Kind;

pub const Base = struct {
    position: u64,
    floor: u64,
    model: []const u8,
};

pub const Recipe = struct {
    /// A base is identified by its unique admission position within the Session.
    frontier: u64 = 0,
    floor: u64 = 0,

    pub fn select(model: []const u8, candidate: ?Base, own_floor: u64) Recipe {
        const base = candidate orelse return .{ .floor = own_floor };
        if (!Kind.compaction.replayableTo(base.model, model, .selected_base)) return .{ .floor = own_floor };
        return .{ .frontier = base.position, .floor = @max(own_floor, base.floor) };
    }

    /// Relational projection of select for an admission's frozen request.
    /// The caller supplies the raw newest base, never an older compatible one.
    pub fn floorSql(comptime model: []const u8, comptime base_model: []const u8, comptime base_floor: []const u8, comptime own_floor: []const u8) []const u8 {
        return "max(coalesce(" ++ own_floor ++ ",0),CASE WHEN " ++ base_model ++ "=" ++ model ++ " THEN coalesce(" ++ base_floor ++ ",0) ELSE 0 END)";
    }

    pub fn anchorSql(comptime model: []const u8, comptime base_model: []const u8, comptime anchor: []const u8) []const u8 {
        return "CASE WHEN " ++ base_model ++ "=" ++ model ++ " THEN coalesce(" ++ anchor ++ ",0) ELSE 0 END";
    }

    /// Model identity is checked by the caller; usage covers only this recipe.
    pub fn measuredBy(recipe: Recipe, measured: Recipe) bool {
        return recipe.frontier == measured.frontier and recipe.floor == measured.floor;
    }
};

test "replay recipe selects only compatible bases and compares effective floors" {
    const base: Base = .{ .position = 10, .floor = 4, .model = "a" };
    const selected = Recipe.select("a", base, 0);
    try std.testing.expectEqual(Recipe{ .frontier = 10, .floor = 4 }, selected);
    try std.testing.expectEqual(Recipe{}, Recipe.select("b", base, 0));
    try std.testing.expectEqual(Recipe{ .floor = 6 }, Recipe.select("b", base, 6));
    try std.testing.expect(selected.measuredBy(Recipe.select("a", base, 4)));
    try std.testing.expect(!selected.measuredBy(Recipe.select("a", base, 6)));
    try std.testing.expect(!selected.measuredBy(Recipe.select("a", null, 4)));
    try std.testing.expect(Recipe.select("b", base, 0).measuredBy(.{}));
}
