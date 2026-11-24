const std = @import("std");
const provider_route = @import("provider_route.zig");
const catalog = @import("model_catalog.zig");
const product_defaults = @import("product_defaults.zig");
const provider_name = @import("provider_name.zig");
const provider_selection = @import("provider_selection.zig");
const connection = @import("connection.zig");

pub const max_model_bytes = catalog.max_model_bytes;
pub const ReasoningEffort = catalog.ReasoningEffort;
pub const validModelSyntax = catalog.validModelSyntax;

pub const CompactionPolicy = struct {
    /// Null when the Session's codec does not compact, so no trigger can fire.
    compaction_trigger: ?u64,
    output_reservation: u64,
};

pub fn supportsModel(facts: []const catalog.Entry, model: []const u8) bool {
    return catalog.find(facts, model) != null;
}

pub fn writeModelHelp(out: *std.Io.Writer, facts: []const catalog.Entry) !void {
    try out.writeAll("Supported model IDs: ");
    var first = true;
    for (facts) |row| if (row.openai_listed) {
        if (!first) try out.writeAll(", ");
        first = false;
        try out.writeAll(row.id);
    };
    try out.writeByte('\n');
}

pub fn writeEffortExceptions(out: *std.Io.Writer, facts: []const catalog.Entry) !void {
    var first = true;
    for (facts) |row| if (row.openai_listed and !row.efforts.contains(.max)) {
        if (!first) try out.writeAll(", ");
        first = false;
        try out.writeAll(row.id);
    };
}

pub const model_help: []const u8 = &rendered_model_help;
pub const ids_without_max_effort: []const u8 = &rendered_effort_exceptions;

const offline_help_bytes = blk: {
    @setEvalBranchQuota(20000);
    var bytes: usize = "Supported model IDs: \n".len;
    for (catalog.shipped) |row| if (row.openai_listed) {
        bytes += row.id.len + ", ".len;
    };
    break :blk bytes;
};
const rendered_model_help = blk: {
    @setEvalBranchQuota(20000);
    var bytes: [offline_help_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    writeModelHelp(&out, catalog.shipped) catch unreachable;
    break :blk bytes[0..out.buffered().len].*;
};
const rendered_effort_exceptions = blk: {
    @setEvalBranchQuota(20000);
    var bytes: [offline_help_bytes]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    writeEffortExceptions(&out, catalog.shipped) catch unreachable;
    break :blk bytes[0..out.buffered().len].*;
};

pub fn supportsReasoningEffort(facts: []const catalog.Entry, model: []const u8, effort: ?ReasoningEffort) bool {
    const row = catalog.find(facts, model) orelse return true;
    return if (effort) |value| row.efforts.contains(value) else row.efforts.count() == 0;
}

pub fn startEffort(facts: []const catalog.Entry, saved: ?ReasoningEffort, model: []const u8) ?ReasoningEffort {
    const effort = saved orelse return null;
    return if (supportsReasoningEffort(facts, model, effort)) effort else null;
}

pub fn contextWindow(facts: []const catalog.Entry, model: []const u8) u64 {
    const row = catalog.find(facts, model) orelse return product_defaults.unlisted_context_window;
    return row.context_window orelse product_defaults.unlisted_context_window;
}

/// The most output tokens a model may take: the catalog's `limit.output`, or the product default when unstated.
pub fn outputLimit(facts: []const catalog.Entry, model: []const u8) u32 {
    const row = catalog.find(facts, model) orelse return product_defaults.unlisted_output_limit;
    return row.output_limit orelse product_defaults.unlisted_output_limit;
}

/// The policy of one Session: `compacts` is its pinned codec's (`codecs.compacts`).
pub fn compactionPolicy(model: []const u8, compacts: bool, trigger_override: ?u64, reservation_override: ?u64) CompactionPolicy {
    _ = model;
    return .{
        .compaction_trigger = if (!compacts) null else trigger_override orelse product_defaults.unlisted_context_window * product_defaults.compaction_trigger_percent / 100,
        .output_reservation = reservation_override orelse product_defaults.output_reservation,
    };
}

const provider_count = @typeInfo(provider_name.Provider).@"enum".field_names.len;

/// The capabilities of the served names, in the Readinesses order. Names point into the readiness they came from,
/// so the list must not outlive it.
pub const Capabilities = struct {
    items: [connection.max_list]provider_selection.Capability = undefined,
    len: usize = 0,

    pub fn slice(self: *const Capabilities) []const provider_selection.Capability {
        return self.items[0..self.len];
    }
};

pub fn capabilities(readiness: *const provider_selection.Readinesses) Capabilities {
    var out: Capabilities = .{};
    for (readiness.names(), readiness.states()) |*name, state| {
        out.items[out.len] = .{ .name = name.slice(), .recommended_model = product_defaults.recommended_model, .admits_model = validModelSyntax, .readiness = state };
        out.len += 1;
    }
    return out;
}

test "compaction policy never infers a spec from the model catalog" {
    for (catalog.shipped) |row| {
        const policy = compactionPolicy(row.id, true, null, null);
        const expected: u64 = 115200;
        try std.testing.expectEqual(expected, policy.compaction_trigger.?);
        try std.testing.expectEqual(@as(u64, 0), policy.output_reservation);
        const overridden = compactionPolicy(row.id, true, 7, 3);
        try std.testing.expectEqual(@as(u64, 7), overridden.compaction_trigger.?);
        try std.testing.expectEqual(@as(u64, 3), overridden.output_reservation);
    }
    for ([_][]const u8{ "model-a", "gpt-6-luna-alias", "GPT-6-LUNA", "gpt-6-lun" }) |other| {
        try std.testing.expectEqual(@as(u64, 115200), compactionPolicy(other, true, null, null).compaction_trigger.?);
        try std.testing.expect(!supportsModel(catalog.shipped, other));
    }
    try std.testing.expectEqual(@as(u64, 11), compactionPolicy("model-a", true, 11, null).compaction_trigger.?);
}

test "a codec that does not compact has no compaction trigger, whatever the override" {
    for ([_]?u64{ null, 7 }) |override| {
        try std.testing.expectEqual(@as(?u64, null), compactionPolicy("model-a", false, override, 3).compaction_trigger);
        try std.testing.expectEqual(@as(u64, 3), compactionPolicy("model-a", false, override, 3).output_reservation);
    }
}

test "CM-11 reasoning effort catalog admission" {
    const efforts = std.enums.values(ReasoningEffort);
    for (0..(@as(usize, 1) << efforts.len)) |mask| {
        var row: catalog.Entry = .{ .id = "selected-model", .context_window = null, .efforts = .empty, .openai_listed = true };
        for (efforts, 0..) |effort, index| if (mask & (@as(usize, 1) << @intCast(index)) != 0) {
            row.efforts.insert(effort);
        };
        const facts = &[_]catalog.Entry{row};
        try std.testing.expectEqual(mask == 0, supportsReasoningEffort(facts, row.id, null));
        for (efforts, 0..) |effort, index| {
            try std.testing.expectEqual(mask & (@as(usize, 1) << @intCast(index)) != 0, supportsReasoningEffort(facts, row.id, effort));
            try std.testing.expect(supportsReasoningEffort(facts, "selected-model-suffix", effort));
        }
        try std.testing.expect(supportsReasoningEffort(facts, "selected-model-suffix", null));
    }

    for (catalog.shipped) |row| {
        try std.testing.expectEqual(row.efforts.count() == 0, supportsReasoningEffort(catalog.shipped, row.id, null));
        inline for (std.meta.tags(ReasoningEffort)) |effort|
            try std.testing.expectEqual(row.efforts.contains(effort), supportsReasoningEffort(catalog.shipped, row.id, effort));
    }
    for ([_]ReasoningEffort{ .low, .medium, .high, .xhigh, .max }) |effort|
        try std.testing.expect(supportsReasoningEffort(catalog.shipped, "gpt-6.1-sol", effort));
    try std.testing.expect(!supportsReasoningEffort(catalog.shipped, "gpt-6.1-sol", .none));
    try std.testing.expect(supportsReasoningEffort(catalog.shipped, "gpt-6.1-terra", .none));
    try std.testing.expect(!supportsReasoningEffort(catalog.shipped, "gpt-5.5", .max));
    for ([_][]const u8{ "model-a", "gpt-6-luna-alias", "GPT-6-LUNA", "gpt-6-lun" }) |unknown| {
        try std.testing.expect(supportsReasoningEffort(catalog.shipped, unknown, null));
        inline for (std.meta.tags(ReasoningEffort)) |effort|
            try std.testing.expect(supportsReasoningEffort(catalog.shipped, unknown, effort));
    }
    try std.testing.expect(std.meta.stringToEnum(ReasoningEffort, "ultra") == null);
}

test "model help lists only OpenAI catalog ids in catalog order" {
    var help: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer help.deinit();
    var exceptions: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer exceptions.deinit();
    try help.writer.writeAll("Supported model IDs: ");
    var count: usize = 0;
    var without_max: usize = 0;
    for (catalog.shipped) |row| if (row.openai_listed) {
        try help.writer.print("{s}{s}", .{ if (count == 0) "" else ", ", row.id });
        try std.testing.expectEqualStrings(row.id, catalog.openai_ids[count]);
        count += 1;
        if (!row.efforts.contains(.max)) {
            try exceptions.writer.print("{s}{s}", .{ if (without_max == 0) "" else ", ", row.id });
            without_max += 1;
        }
    };
    try help.writer.writeByte('\n');
    try std.testing.expectEqual(count, catalog.openai_ids.len);
    try std.testing.expectEqualStrings(help.written(), model_help);
    try std.testing.expectEqualStrings(exceptions.written(), ids_without_max_effort);
}

test "a new Session keeps saved effort unless its listed model excludes it" {
    try std.testing.expectEqual(@as(?ReasoningEffort, .max), startEffort(catalog.shipped, .max, "gpt-6-luna"));
    try std.testing.expectEqual(@as(?ReasoningEffort, null), startEffort(catalog.shipped, .max, "gpt-5.5"));
    try std.testing.expectEqual(@as(?ReasoningEffort, .max), startEffort(catalog.shipped, .max, "unlisted-model"));
    try std.testing.expectEqual(@as(?ReasoningEffort, null), startEffort(catalog.shipped, null, "gpt-6-luna"));
}

test "selection admits any ID with valid syntax, listed or not" {
    var readiness: provider_selection.Readinesses = .initFill(.missing);
    readiness.set(provider_route.nameOf(.codex), .configured);
    const selectable = capabilities(&readiness).slice();
    try std.testing.expectEqualStrings("family=variant", (try provider_selection.resolve(selectable, null, "family=variant", null, null)).selected.model);
    try std.testing.expectEqualStrings("stale-pin", (try provider_selection.resolve(selectable, null, null, "codex", "stale-pin")).selected.model);
    try std.testing.expectEqualStrings(product_defaults.recommended_model, (try provider_selection.resolve(selectable, null, null, null, null)).selected.model);
    try std.testing.expectError(error.UnsupportedSelectionModel, provider_selection.resolve(selectable, null, "bad model", null, null));
}

test "every built-in provider is selectable by its label, and two ready ones ask for a choice" {
    var readiness: provider_selection.Readinesses = .initFill(.configured);
    const both = capabilities(&readiness).slice();
    try std.testing.expectEqual(provider_selection.Selection.chooser, try provider_selection.resolve(both, null, null, null, null));
    try std.testing.expectEqualStrings("openai", (try provider_selection.resolve(both, "openai", null, null, null)).selected.provider);
    readiness.set(provider_route.nameOf(.codex), .missing);
    readiness.set(provider_route.nameOf(.chatgpt), .missing);
    const one = capabilities(&readiness).slice();
    try std.testing.expectEqualStrings("openai", (try provider_selection.resolve(one, null, null, null, null)).selected.provider);
}

test "selected facts alone own capability effort context and help" {
    const facts: []const catalog.Entry = &.{
        .{ .id = "a-saved", .context_window = 321, .efforts = .init(.{ .high = true }), .openai_listed = true },
        .{ .id = "gpt-6-luna", .context_window = 123, .efforts = .{}, .openai_listed = false },
        .{ .id = "z-saved", .context_window = null, .efforts = .init(.{ .max = true }), .openai_listed = true },
    };
    for (facts) |row| {
        try std.testing.expect(supportsModel(facts, row.id));
        try std.testing.expectEqual(row.efforts.count() == 0, supportsReasoningEffort(facts, row.id, null));
        try std.testing.expectEqual(@as(u64, row.context_window orelse product_defaults.unlisted_context_window), contextWindow(facts, row.id));
        inline for (std.meta.tags(ReasoningEffort)) |effort| {
            try std.testing.expectEqual(row.efforts.contains(effort), supportsReasoningEffort(facts, row.id, effort));
            try std.testing.expectEqual(if (row.efforts.contains(effort)) @as(?ReasoningEffort, effort) else null, startEffort(facts, effort, row.id));
        }
    }
    for ([_][]const catalog.Entry{ facts, &.{} }) |selected| {
        try std.testing.expect(!supportsModel(selected, "gpt-5.5"));
        try std.testing.expect(supportsReasoningEffort(selected, "gpt-5.5", null));
        try std.testing.expectEqual(product_defaults.unlisted_context_window, contextWindow(selected, "gpt-5.5"));
        inline for (std.meta.tags(ReasoningEffort)) |effort| {
            try std.testing.expect(supportsReasoningEffort(selected, "gpt-5.5", effort));
            try std.testing.expectEqual(@as(?ReasoningEffort, effort), startEffort(selected, effort, "gpt-5.5"));
        }
    }
    var help: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer help.deinit();
    try writeModelHelp(&help.writer, facts);
    try std.testing.expectEqualStrings("Supported model IDs: a-saved, z-saved\n", help.written());
    help.clearRetainingCapacity();
    try writeEffortExceptions(&help.writer, facts);
    try std.testing.expectEqualStrings("a-saved", help.written());
    help.clearRetainingCapacity();
    try writeModelHelp(&help.writer, &.{});
    try std.testing.expectEqualStrings("Supported model IDs: \n", help.written());
    help.clearRetainingCapacity();
    try writeEffortExceptions(&help.writer, &.{});
    try std.testing.expectEqualStrings("", help.written());
}

test "capabilities name each served connection by its name, so alpha and beta select by name" {
    var readiness: provider_selection.Readinesses = .initFill(.missing);
    const alpha = connection.Name.parse("alpha").?;
    const beta = connection.Name.parse("beta").?;
    readiness.set(alpha, .configured);
    readiness.set(beta, .renewal_due);
    const list = capabilities(&readiness).slice();
    try std.testing.expectEqualStrings("alpha", list[list.len - 2].name);
    try std.testing.expectEqualStrings("beta", list[list.len - 1].name);
    try std.testing.expectEqualStrings("beta", (try provider_selection.resolve(list, "beta", null, null, null)).selected.provider);
    try std.testing.expectEqual(provider_selection.Selection.chooser, try provider_selection.resolve(list, null, null, null, null));
    try std.testing.expectError(error.UnsupportedSelectionProvider, provider_selection.resolve(list, "gamma", null, null, null));
}
