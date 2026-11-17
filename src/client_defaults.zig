const std = @import("std");
const catalog = @import("model_catalog.zig");
const capability = @import("model_capability.zig");
const defaults = @import("product_defaults.zig");

/// Preserve personal saved-effort compatibility until preferences move to the
/// Host (#1629). The wire sends this saved preference as an explicit value, so
/// retain its existing product fallback when the model cannot use the saved choice.
pub fn savedEffort(model: []const u8, saved: catalog.ReasoningEffort) ?catalog.ReasoningEffort {
    const preferred = comptime std.meta.stringToEnum(catalog.ReasoningEffort, defaults.reasoning_effort).?;
    return capability.startEffort(catalog.shipped, saved, model) orelse capability.startEffort(catalog.shipped, preferred, model) orelse blk: {
        const row = catalog.find(catalog.shipped, model) orelse break :blk null;
        var efforts = row.efforts.iterator();
        break :blk efforts.next();
    };
}

test "saved effort keeps supported preferences and its existing product fallback" {
    try std.testing.expectEqual(catalog.ReasoningEffort.max, savedEffort("gpt-6.1-sol", .max).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.low, savedEffort("gpt-5.5", .max).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.low, savedEffort("gpt-6-luna", .low).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.none, savedEffort("gpt-6.1-terra", .none).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.none, savedEffort("@cf/moonshotai/kimi-k2.6", .low).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.high, savedEffort("azure/gpt-5-pro", .low).?);
    try std.testing.expect(savedEffort("openai/whisper-1", .low) == null);
    try std.testing.expectEqual(catalog.ReasoningEffort.low, savedEffort("whisper-1", .low).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.low, savedEffort("unlisted-model", .low).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.max, savedEffort("unlisted-model", .max).?);
    for (catalog.shipped) |row| {
        if (savedEffort(row.id, .low)) |effort| {
            try std.testing.expect(row.efforts.contains(effort));
            if (row.efforts.contains(.low)) try std.testing.expectEqual(catalog.ReasoningEffort.low, effort) else {
                var efforts = row.efforts.iterator();
                try std.testing.expectEqual(efforts.next().?, effort);
            }
        } else try std.testing.expectEqual(@as(usize, 0), row.efforts.count());
    }
}
