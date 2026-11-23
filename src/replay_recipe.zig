const std = @import("std");
const replay_binding = @import("replay_binding.zig");

pub const Base = struct {
    position: u64,
    floor: u64,
    /// The Binding that produced the base (its Wire and the model it ran on).
    binding: replay_binding.Binding,
};

pub const Recipe = struct {
    frontier: u64 = 0,
    floor: u64 = 0,

    /// `request` is the Binding the next request is built for. A base that the request cannot
    /// replay selects nothing.
    pub fn select(request: replay_binding.Binding, candidate: ?Base, own_floor: u64) Recipe {
        const base = candidate orelse return .{ .floor = own_floor };
        if (replay_binding.decide(.compaction, base.binding, request, .selected_base) == .omit) return .{ .floor = own_floor };
        return .{ .frontier = base.position, .floor = @max(own_floor, base.floor) };
    }

    pub fn floorSql(comptime model: []const u8, comptime base_model: []const u8, comptime base_floor: []const u8, comptime own_floor: []const u8) []const u8 {
        return "max(coalesce(" ++ own_floor ++ ",0),CASE WHEN " ++ base_model ++ "=" ++ model ++ " THEN coalesce(" ++ base_floor ++ ",0) ELSE 0 END)";
    }

    pub fn anchorSql(comptime model: []const u8, comptime base_model: []const u8, comptime anchor: []const u8) []const u8 {
        return "CASE WHEN " ++ base_model ++ "=" ++ model ++ " THEN coalesce(" ++ anchor ++ ",0) ELSE 0 END";
    }

    pub fn measuredBy(recipe: Recipe, measured: Recipe) bool {
        return recipe.frontier == measured.frontier and recipe.floor == measured.floor;
    }
};

test "replay recipe selects only compatible bases and compares effective floors" {
    const wire: replay_binding.Wire = .{ .connection = "marlin", .dialect = .openai_responses };
    const base: Base = .{ .position = 10, .floor = 4, .binding = .{ .wire = wire, .model = "a" } };
    const selected = Recipe.select(.{ .wire = wire, .model = "a" }, base, 0);
    try std.testing.expectEqual(Recipe{ .frontier = 10, .floor = 4 }, selected);
    try std.testing.expectEqual(Recipe{}, Recipe.select(.{ .wire = wire, .model = "b" }, base, 0));
    try std.testing.expectEqual(Recipe{ .floor = 6 }, Recipe.select(.{ .wire = wire, .model = "b" }, base, 6));
    try std.testing.expect(selected.measuredBy(Recipe.select(.{ .wire = wire, .model = "a" }, base, 4)));
    try std.testing.expect(!selected.measuredBy(Recipe.select(.{ .wire = wire, .model = "a" }, base, 6)));
    try std.testing.expect(!selected.measuredBy(Recipe.select(.{ .wire = wire, .model = "a" }, null, 4)));
    try std.testing.expect(Recipe.select(.{ .wire = wire, .model = "b" }, base, 0).measuredBy(.{}));
}
