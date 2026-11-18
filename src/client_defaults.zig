const std = @import("std");
const catalog = @import("model_catalog.zig");
const capability = @import("model_capability.zig");
const defaults = @import("product_defaults.zig");
const Provider = @import("provider_name.zig").Provider;

pub fn compactionTrigger(provider: Provider, model: []const u8) u64 {
    const model_trigger = capability.contextWindow(catalog.shipped, model) * defaults.compaction_trigger_percent / 100;
    const provider_trigger = for (defaults.provider_compaction_triggers) |entry| {
        if (std.mem.eql(u8, entry.provider, @tagName(provider))) break entry.tokens;
    } else model_trigger;
    const trigger = for (defaults.model_compaction_triggers) |entry| {
        if (std.mem.eql(u8, entry.provider, @tagName(provider)) and std.mem.eql(u8, entry.model, model)) break entry.tokens;
    } else provider_trigger;
    return @min(trigger, model_trigger);
}

pub fn startEffort(model: []const u8, saved: ?catalog.ReasoningEffort) ?catalog.ReasoningEffort {
    const preferred = comptime std.meta.stringToEnum(catalog.ReasoningEffort, defaults.reasoning_effort).?;
    return capability.startEffort(catalog.shipped, saved, model) orelse capability.startEffort(catalog.shipped, preferred, model) orelse blk: {
        const row = catalog.find(catalog.shipped, model) orelse break :blk null;
        var efforts = row.efforts.iterator();
        break :blk efforts.next();
    };
}

test "CM-39 default compaction trigger" {
    const cases = [_]struct { provider: Provider, model: []const u8, tokens: u64 }{
        .{ .provider = .codex, .model = "gpt-6.1-sol", .tokens = 450000 },
        .{ .provider = .codex, .model = "gpt-6.1-terra", .tokens = 450000 },
        .{ .provider = .codex, .model = "gpt-6.2-sol", .tokens = 450000 },
        .{ .provider = .codex, .model = "gpt-6.2-astra", .tokens = 244800 },
        .{ .provider = .codex, .model = "gpt-6-sol", .tokens = 244800 },
        .{ .provider = .codex, .model = "gpt-6.1-terra@eu", .tokens = 244800 },
        .{ .provider = .codex, .model = "openai/gpt-6.1-terra", .tokens = 244800 },
        .{ .provider = .codex, .model = "gpt-6.1-terra-extra", .tokens = 115200 },
        .{ .provider = .codex, .model = "gpt-5.3-codex-spark", .tokens = 115200 },
        .{ .provider = .codex, .model = "unlisted-model", .tokens = 115200 },
        .{ .provider = .openai, .model = "gpt-6.1-terra", .tokens = 945000 },
        .{ .provider = .openai, .model = "gpt-6.2-sol", .tokens = 945000 },
        .{ .provider = .openai, .model = "gpt-5.3-codex-spark", .tokens = 115200 },
        .{ .provider = .openai, .model = "unlisted-model", .tokens = 115200 },
    };
    for (cases) |case| try std.testing.expectEqual(case.tokens, compactionTrigger(case.provider, case.model));
}

test "client start effort uses catalog effort admission" {
    try std.testing.expectEqual(catalog.ReasoningEffort.max, startEffort("gpt-6.1-sol", .max).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.low, startEffort("gpt-5.5", .max).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.low, startEffort("gpt-6-luna", null).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.none, startEffort("gpt-6.1-terra", .none).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.none, startEffort("@cf/moonshotai/kimi-k2.6", null).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.high, startEffort("azure/gpt-5-pro", .low).?);
    try std.testing.expect(startEffort("openai/whisper-1", .low) == null);
    try std.testing.expectEqual(catalog.ReasoningEffort.low, startEffort("whisper-1", .low).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.low, startEffort("unlisted-model", null).?);
    try std.testing.expectEqual(catalog.ReasoningEffort.max, startEffort("unlisted-model", .max).?);
    for (catalog.shipped) |row| {
        if (startEffort(row.id, null)) |effort| {
            try std.testing.expect(row.efforts.contains(effort));
            if (row.efforts.contains(.low)) try std.testing.expectEqual(catalog.ReasoningEffort.low, effort) else {
                var efforts = row.efforts.iterator();
                try std.testing.expectEqual(efforts.next().?, effort);
            }
        } else try std.testing.expectEqual(@as(usize, 0), row.efforts.count());
    }
}
