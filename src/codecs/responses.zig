//! The OpenAI Responses codec (`openai-responses/1`), serving the `codex`
//! provider.
const std = @import("std");
const codec_abi = @import("../codec_abi.zig");

pub const manifest: codec_abi.Manifest = .{
    .observe = .{
        .request_id = "x-request-id",
        .model = "openai-model",
        .alternate_model = "x-openai-model",
        .turn_state = "x-codex-turn-state",
    },
};

/// Models that get `parallel_tool_calls: true`; every other model, known or
/// not, gets `false`. Codex 970111f6cb62cc02fe36a82ea7d71b37a2889c97
/// client.rs disables it for Responses-lite models although its catalog
/// advertises it for all; this is not a claim that Rui uses the lite route.
/// The body this table shapes is pinned with the codec version.
const parallel_tool_call_models = [_][]const u8{"gpt-5.5"};

pub fn parallelToolCalls(model: []const u8) bool {
    for (parallel_tool_call_models) |id| if (std.mem.eql(u8, id, model)) return true;
    return false;
}

/// The encoder's only state between input items is whether one was
/// written, since the next then takes a comma.
pub fn carry(input_comma: bool) codec_abi.Carry {
    return codec_abi.Carry.of(&.{@intFromBool(input_comma)});
}

pub fn inputComma(state: *const codec_abi.Carry) bool {
    std.debug.assert(state.len == 1 and state.bytes[0] <= 1);
    return state.bytes[0] == 1;
}

/// A tool's Responses `function` entry, built at compile time.
pub fn toolJson(comptime tool: codec_abi.ToolDefinition) []const u8 {
    return comptime "{\"type\":\"function\",\"name\":\"" ++ jsonString(tool.name) ++
        "\",\"description\":\"" ++ jsonString(tool.description) ++
        "\",\"strict\":true,\"parameters\":" ++ tool.parameters_json ++ "}";
}

/// The JSON string body of `text`, escaped as std.json writes it: quote,
/// backslash and C0 controls, everything else (UTF-8 included) verbatim.
fn jsonString(comptime text: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (text) |byte| out = out ++ switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0x08 => "\\b",
            0x0c => "\\f",
            0...0x07, 0x0b, 0x0e...0x1f => std.fmt.comptimePrint("\\u{x:0>4}", .{byte}),
            else => &[_]u8{byte},
        };
        return out;
    }
}

test "only the pinned table's models send parallel tool calls" {
    try std.testing.expect(parallelToolCalls("gpt-5.5"));
    for ([_][]const u8{ "gpt-6.1-sol", "gpt-6-luna", "GPT-5.5", "gpt-5.5-mini", "gpt-5", "" }) |model|
        try std.testing.expect(!parallelToolCalls(model));
}

test "a carry holds exactly the comma state the span ended in" {
    for ([_]bool{ false, true }) |input_comma| {
        const state = carry(input_comma);
        try std.testing.expectEqual(input_comma, inputComma(&state));
        try std.testing.expect(state.eql(&carry(input_comma)));
        try std.testing.expect(!state.eql(&carry(!input_comma)));
    }
}

test "a tool entry escapes its name and description as JSON strings" {
    const json = toolJson(.{ .name = "t", .description = "say \"hi\"\\\n\x01é", .parameters_json = "{}" });
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("say \"hi\"\\\n\x01é", parsed.value.object.get("description").?.string);
    try std.testing.expectEqualStrings("{\"type\":\"function\",\"name\":\"t\",\"description\":\"say \\\"hi\\\"\\\\\\n\\u0001é\",\"strict\":true,\"parameters\":{}}", json);
}
