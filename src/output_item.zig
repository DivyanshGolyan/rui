//! Canonical output item kinds and their model replay rule.
const std = @import("std");

pub const Use = enum { history, selected_base };

pub const Kind = enum(u8) {
    reasoning = 1,
    message = 2,
    function_call = 3,
    compaction = 4,
    web_search_call = 5,

    /// Opaque state belongs to the producing Operation's requested model,
    /// never its served-model evidence. Visible output survives a switch;
    /// only the selected compaction replaces history, never an older one.
    pub fn replayableTo(kind: Kind, producing_model: []const u8, requested_model: []const u8, use: Use) bool {
        return switch (kind) {
            .reasoning => std.mem.eql(u8, producing_model, requested_model),
            .compaction => use == .selected_base and std.mem.eql(u8, producing_model, requested_model),
            .message, .function_call, .web_search_call => true,
        };
    }
};

test "output replay keeps visible items across models and opaque items only on their model" {
    inline for (std.meta.tags(Kind)) |kind| {
        for ([_]Use{ .history, .selected_base }) |use| {
            try std.testing.expectEqual(kind != .compaction or use == .selected_base, kind.replayableTo("model-a", "model-a", use));
            const visible = switch (kind) {
                .message, .function_call, .web_search_call => true,
                .reasoning, .compaction => false,
            };
            try std.testing.expectEqual(visible, kind.replayableTo("model-a", "model-b", use));
        }
    }
}
