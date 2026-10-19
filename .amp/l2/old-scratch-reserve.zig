const std = @import("std");
const ScratchBudget = @import("budget");

pub fn main() void {
    var used: std.atomic.Value(u64) = .init(0);
    const budget = ScratchBudget{ .used = &used, .limit = 1 };
    _ = budget.reserve(1);
}
