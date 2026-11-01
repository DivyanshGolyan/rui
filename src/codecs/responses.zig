//! The OpenAI Responses codec (`openai-responses/1`), serving the `codex`
//! provider.
const std = @import("std");
const codec_abi = @import("../codec_abi.zig");
const json = @import("json.zig");

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

const ItemHeader = codec_abi.ItemHeader;
const Ops = codec_abi.Ops;
const Status = codec_abi.Status;

/// The request encoder. Between history elements its whole state is
/// whether one was written, since the next input item then takes a comma;
/// that is its carry. The rest lives only within one output item or the
/// tools array.
pub const Encoder = struct {
    input_comma: bool = false,
    /// The open output item's replay rule and the part array it has open.
    omit_reasoning_text: bool = false,
    array: codec_abi.PartArray = .none,
    tool_comma: bool = false,

    pub const Error = error{ BadCarry, UnsupportedItem, OpsOverflow };

    /// An empty carry is the state before the first input item.
    pub fn load(carry: *const codec_abi.Carry) error{BadCarry}!Encoder {
        const state = carry.slice();
        if (state.len == 0) return .{};
        if (state.len != 1 or state[0] > 1) return error.BadCarry;
        return .{ .input_comma = state[0] == 1 };
    }

    pub fn encodeItem(self: *Encoder, header: *const ItemHeader, ops: *Ops) Error!Status {
        switch (header.item) {
            .settings => |*settings| {
                // Codex routes a Session's requests by its session id.
                try ops.header("accept", "text/event-stream");
                try ops.header("session-id", &std.fmt.bytesToHex(settings.session_affinity, .lower));
                try ops.header("originator", "rui");
                try ops.literal("{\"model\":\"");
                try ops.content(0, .json_string_v1);
                try ops.literal(if (parallelToolCalls(settings.modelName())) envelope(true) else envelope(false));
                if (settings.effort) |effort| try ops.literal(switch (effort) {
                    inline else => |value| ",\"reasoning\":{\"effort\":\"" ++ @tagName(value) ++ "\"}",
                });
            },
            .instructions => {
                try ops.literal(",\"instructions\":\"");
                try ops.content(0, .json_string_v1);
                try ops.literal("\",\"input\":[");
            },
            .message => |author| {
                try self.separateInput(ops);
                try ops.literal(switch (author) {
                    .user => "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"",
                    .instruction => "{\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"",
                });
                // A peer Message's sender is its own leading part, separate
                // from the text the peer wrote.
                if (header.has(1)) {
                    try ops.content(1, .json_string_v1);
                    try ops.literal("\"},{\"type\":\"input_text\",\"text\":\"");
                }
                try ops.content(0, .json_string_v1);
                try ops.literal("\"}]}");
                try self.writeCarry(ops);
            },
            // An output item is rebuilt from Rui's form and its provider
            // bags, written canonically: the model receives what it sent.
            .output_open => |output| {
                try self.separateInput(ops);
                self.omit_reasoning_text = output.omit_reasoning_text;
                self.array = .none;
                switch (output.kind) {
                    .reasoning => try ops.literal("{\"type\":\"reasoning\""),
                    .compaction => try ops.literal("{\"type\":\"compaction\""),
                    .message => try ops.literal(switch (output.phase) {
                        .unphased => "{\"type\":\"message\",\"role\":\"assistant\"",
                        .commentary => "{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"commentary\"",
                        .final_answer => "{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\"",
                    }),
                    .function_call => {
                        try ops.literal("{\"type\":\"function_call\",\"name\":\"");
                        try ops.content(0, .json_string_v1);
                        try ops.literal("\",\"call_id\":\"");
                        try ops.content(1, .json_string_v1);
                        try ops.literal("\",\"arguments\":\"");
                        try ops.content(2, .json_string_v1);
                        try ops.literal("\"");
                    },
                }
            },
            .output_part => |part| {
                // Private reasoning text is never replay input.
                if (self.omit_reasoning_text and part.array == .content) return .next;
                if (self.array == part.array) {
                    try ops.literal(",");
                } else {
                    if (self.array != .none) try ops.literal("]");
                    try ops.literal(if (part.array == .content) ",\"content\":[" else ",\"summary\":[");
                    self.array = part.array;
                }
                if (header.has(0)) {
                    try ops.literal(switch (part.kind) {
                        .output_text => "{\"type\":\"output_text\",\"text\":\"",
                        .refusal => "{\"type\":\"refusal\",\"refusal\":\"",
                        .summary_text => "{\"type\":\"summary_text\",\"text\":\"",
                        .reasoning_text => "{\"type\":\"reasoning_text\",\"text\":\"",
                        .opaque_block => return error.UnsupportedItem,
                    });
                    try ops.content(0, .json_string_v1);
                    if (header.has(1)) {
                        try ops.literal("\",");
                        try ops.content(1, .verbatim);
                        try ops.literal("}");
                    } else try ops.literal("\"}");
                } else {
                    try ops.literal("{");
                    try ops.content(1, .verbatim);
                    try ops.literal("}");
                }
            },
            .output_close => {
                if (self.array != .none) try ops.literal("]");
                if (header.has(0)) {
                    try ops.literal(",");
                    try ops.content(0, .verbatim);
                }
                try ops.literal("}");
                try self.writeCarry(ops);
            },
            .tool_result => {
                try self.separateInput(ops);
                try ops.literal("{\"type\":\"function_call_output\",\"call_id\":\"");
                try ops.content(0, .json_string_v1);
                try ops.literal("\",\"output\":\"");
                try ops.content(1, .json_string_v1);
                try ops.literal("\"}");
                try self.writeCarry(ops);
            },
            .history_end => {},
            .compaction_trigger => {
                try self.separateInput(ops);
                try ops.literal("{\"type\":\"compaction_trigger\"}");
            },
            .tools_start => try ops.literal("],\"tools\":["),
            .tool => {
                if (self.tool_comma) try ops.literal(",");
                self.tool_comma = true;
                try ops.literal("{\"type\":\"function\",\"name\":\"");
                try ops.content(0, .json_string_v1);
                try ops.literal("\",\"description\":\"");
                try ops.content(1, .json_string_v1);
                try ops.literal("\",\"strict\":true,\"parameters\":");
                try ops.content(2, .verbatim);
                try ops.literal("}");
            },
            // The tools array closes here, after its last tool.
            .text_format => if (header.has(0)) {
                try ops.literal("],\"text\":{\"verbosity\":\"low\",\"format\":{\"type\":\"json_schema\",\"name\":\"rui_output\",\"strict\":true,\"schema\":");
                try ops.content(0, .verbatim);
                try ops.literal("}}");
            } else try ops.literal("],\"text\":{\"verbosity\":\"low\"}"),
            .request_end => {
                try ops.literal("}");
                return .done;
            },
        }
        return .next;
    }

    /// An input item after another takes a comma.
    fn separateInput(self: *Encoder, ops: *Ops) error{OpsOverflow}!void {
        if (self.input_comma) try ops.literal(",");
        self.input_comma = true;
    }

    fn writeCarry(self: *const Encoder, ops: *Ops) error{OpsOverflow}!void {
        try ops.carry(&.{@intFromBool(self.input_comma)});
    }
};

/// Reads an HTTP error body. A Responses body is one JSON object whose
/// `error` object names the failure: its `code` (and, for a quota, its
/// `resets_at`), its `type` standing in for a missing code in the report,
/// and its `message`, else a bare `detail`; a body without `error` reports
/// only its own `message` or `detail`. Only a whole valid body and members
/// that appear once count. The reader holds the state for any body size,
/// and the report is named by range, so nothing of the body is buffered.
pub const Classifier = struct {
    reader: json.Reader,
    /// The named member being read: of the body, and of its error object.
    outer: Outer,
    inner: Inner,
    /// Whether the body's `error` member is an object.
    error_object: bool,
    envelope: std.EnumArray(Outer, Member),
    failure: std.EnumArray(Inner, Member),
    /// The error object's code, when it is a string of at most
    /// max_code_bytes; empty otherwise.
    code: [codec_abi.max_code_bytes]u8,
    code_length: u8,
    /// The error object's `resets_at`, when it is a plain integer.
    resets_at: ?u64,

    const Outer = enum { other, @"error", message, detail };
    const Inner = enum { other, code, type, message, detail, resets_at };

    const Member = struct {
        /// How often it appears, counting no further than a duplicate.
        count: u2 = 0,
        /// Whether its last value is a string, which `range` holds.
        is_string: bool = false,
        range: json.Range = .{ .start = 0, .length = 0 },

        fn string(self: Member) ?json.Range {
            return if (self.is_string) self.range else null;
        }

        fn set(self: *Member, range: json.Range) void {
            self.is_string = true;
            self.range = range;
        }
    };

    pub const Error = error{OpsOverflow};

    pub fn init(self: *Classifier) void {
        self.* = .{
            .reader = .{},
            .outer = .other,
            .inner = .other,
            .error_object = false,
            .envelope = .initFill(.{}),
            .failure = .initFill(.{}),
            .code = undefined,
            .code_length = 0,
            .resets_at = null,
        };
    }

    pub fn classify(self: *Classifier, fed: *const codec_abi.Fed, ops: *Ops) Error!Status {
        // A body that is not JSON establishes nothing.
        self.reader.feed(fed.bytes, self) catch return .done;
        if (!fed.end) return .next;
        if (self.reader.complete()) try self.find(ops);
        return .done;
    }

    fn find(self: *Classifier, ops: *Ops) Error!void {
        const failure = self.envelope.get(.@"error");
        if (failure.count == 0) return report(ops, .message, message(&self.envelope));
        if (failure.count > 1 or !self.error_object) return;
        const code = self.failure.get(.code);
        if (code.count == 1 and self.code_length != 0) {
            const text = self.code[0..self.code_length];
            if (std.mem.eql(u8, text, "context_length_exceeded")) {
                try ops.finding(.context_overflow);
            } else {
                const resets_at = if (self.failure.get(.resets_at).count == 1) self.resets_at else null;
                try ops.finding(.{ .quota = .{ .code = text, .resets_at = resets_at } });
                try ops.finding(.{ .refusal = text });
            }
        }
        // An error object's type stands in for a code that is absent, empty
        // or not a string.
        const named = code.count == 1 and code.is_string and code.range.length != 0;
        const kind = self.failure.get(.type);
        try report(ops, .code, if (named) code.range else if (kind.count == 1) kind.string() else null);
        try report(ops, .message, message(&self.failure));
    }

    /// `message`, else `detail`; a message that is not a string is left out.
    fn message(members: anytype) ?json.Range {
        const text = members.get(.message);
        if (text.count == 1) return text.string();
        const detail = members.get(.detail);
        return if (detail.count == 1) detail.string() else null;
    }

    fn report(ops: *Ops, field: codec_abi.ReportField, range: ?json.Range) Error!void {
        const value = range orelse return;
        try ops.finding(.{ .report = .{ .field = field, .escape = .json_string_v1, .start = value.start, .length = value.length } });
    }

    pub fn key(self: *Classifier, reader: *const json.Reader, depth: u8) void {
        const name = reader.text() orelse "";
        switch (depth) {
            1 => self.outer = std.meta.stringToEnum(Outer, name) orelse .other,
            2 => if (self.inError()) {
                self.inner = std.meta.stringToEnum(Inner, name) orelse .other;
            },
            else => {},
        }
    }

    pub fn begin(self: *Classifier, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        _ = reader;
        switch (depth) {
            1 => {
                if (self.outer == .other) return;
                start(self.envelope.getPtr(self.outer));
                if (self.outer == .@"error") self.error_object = kind == .object;
            },
            2 => if (self.inError() and self.inner != .other) {
                start(self.failure.getPtr(self.inner));
                if (self.inner == .code) self.code_length = 0;
                if (self.inner == .resets_at) self.resets_at = null;
            },
            else => {},
        }
    }

    pub fn end(self: *Classifier, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        switch (depth) {
            1 => if (kind == .string and self.outer != .other) {
                self.envelope.getPtr(self.outer).set(reader.string());
            },
            2 => if (self.inError() and self.inner != .other) switch (kind) {
                .string => {
                    self.failure.getPtr(self.inner).set(reader.string());
                    if (self.inner == .code) if (reader.text()) |text| {
                        @memcpy(self.code[0..text.len], text);
                        self.code_length = @intCast(text.len);
                    };
                },
                .number => if (self.inner == .resets_at) {
                    self.resets_at = reader.integer;
                },
                else => {},
            },
            else => {},
        }
    }

    /// Whether the reader is among the members of the body's error object.
    fn inError(self: *const Classifier) bool {
        return self.outer == .@"error" and self.error_object;
    }

    fn start(member: *Member) void {
        member.count +|= 1;
        member.is_string = false;
    }
};

fn envelope(comptime parallel_tool_calls: bool) []const u8 {
    return "\",\"parallel_tool_calls\":" ++ (if (parallel_tool_calls) "true" else "false") ++
        ",\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"]";
}

test "only the pinned table's models send parallel tool calls" {
    try std.testing.expect(parallelToolCalls("gpt-5.5"));
    for ([_][]const u8{ "gpt-6.1-sol", "gpt-6-luna", "GPT-5.5", "gpt-5.5-mini", "gpt-5", "" }) |model|
        try std.testing.expect(!parallelToolCalls(model));
}

test "a carry holds exactly the comma state the span ended in" {
    for ([_]bool{ false, true }) |input_comma| {
        const loaded = try Encoder.load(&codec_abi.Carry.of(&.{@intFromBool(input_comma)}));
        try std.testing.expectEqual(Encoder{ .input_comma = input_comma }, loaded);
        // Every element ends with the carry of the state after it.
        var encoder = loaded;
        var header: ItemHeader = undefined;
        header.item = .tool_result;
        header.handles = 0b11;
        var ops: Ops = .{};
        try std.testing.expectEqual(Status.next, try encoder.encodeItem(&header, &ops));
        try std.testing.expect(std.mem.endsWith(u8, ops.bytes[0..ops.length], &.{ @backingInt(codec_abi.OpTag.carry), 1, 1 }));
        const first: []const u8 = if (input_comma) &.{ 1, 1, 0, ',' } else &.{ 1, 42, 0 };
        try std.testing.expect(std.mem.startsWith(u8, ops.bytes[0..ops.length], first));
    }
    try std.testing.expectEqual(Encoder{}, try Encoder.load(&.{}));
    for ([_][]const u8{ &.{2}, &.{ 0, 0 } }) |state|
        try std.testing.expectError(error.BadCarry, Encoder.load(&codec_abi.Carry.of(state)));
}

test "the largest item the codec emits fits the ops bound" {
    // Every item at its longest: each effort, each output kind and phase,
    // each part after each array, every handle present, and a comma owed
    // before it.
    var headers: [64]ItemHeader = undefined;
    var count: usize = 0;
    for ([_]?codec_abi.Effort{null} ++ std.enums.values(codec_abi.Effort)) |effort| {
        headers[count] = .{ .item = .{ .settings = .{ .effort = effort, .session_affinity = @splat(0xff), .model_length = 0 } }, .handles = 0b1 };
        count += 1;
    }
    for (std.enums.values(codec_abi.Author)) |author| {
        headers[count] = .{ .item = .{ .message = author }, .handles = 0b11 };
        count += 1;
    }
    for (std.enums.values(codec_abi.OutputKind)) |kind| for (std.enums.values(codec_abi.Phase)) |phase| {
        headers[count] = .{ .item = .{ .output_open = .{ .kind = kind, .phase = phase, .omit_reasoning_text = false } }, .handles = 0b111 };
        count += 1;
    };
    for ([_]codec_abi.PartArray{ .content, .summary }) |array| for (std.enums.values(codec_abi.PartKind)) |kind| {
        if (kind == .opaque_block) continue;
        headers[count] = .{ .item = .{ .output_part = .{ .array = array, .kind = kind } }, .handles = 0b11 };
        count += 1;
    };
    for ([_]codec_abi.Item{ .instructions, .output_close, .tool_result, .history_end, .compaction_trigger, .tools_start, .tool, .text_format, .request_end }) |item| {
        headers[count] = .{ .item = item, .handles = 0b111 };
        count += 1;
    }
    for (headers[0..count]) |*header| {
        // An open array of the other kind is closed first.
        var encoder: Encoder = .{ .input_comma = true, .tool_comma = true, .array = .summary };
        if (header.item == .output_part and header.item.output_part.array == .summary) encoder.array = .content;
        var ops: Ops = .{};
        _ = try encoder.encodeItem(header, &ops);
    }
    // The model is written by a content op, so its length never counts.
    var longest: ItemHeader = .{ .item = .{ .settings = .{ .effort = .medium, .session_affinity = @splat(0), .model_length = codec_abi.max_model_bytes } }, .handles = 0b1 };
    @memset(&longest.item.settings.model, 'm');
    var shortest = longest;
    shortest.item.settings.model_length = 1;
    var longest_ops: Ops = .{};
    var shortest_ops: Ops = .{};
    var encoder: Encoder = .{};
    _ = try encoder.encodeItem(&longest, &longest_ops);
    _ = try encoder.encodeItem(&shortest, &shortest_ops);
    try std.testing.expectEqual(shortest_ops.length, longest_ops.length);
}

test "the settings item asks for the stream, the Session's id and Rui as originator" {
    var header: ItemHeader = .{ .item = .{ .settings = .{ .effort = null, .session_affinity = .{ 0x00, 0x01, 0x7f, 0x80, 0xab, 0xff } ++ @as([10]u8, @splat(0x10)), .model_length = 1 } }, .handles = 0b1 };
    header.item.settings.model[0] = 'm';
    var encoder: Encoder = .{};
    var ops: Ops = .{};
    try std.testing.expectEqual(Status.next, try encoder.encodeItem(&header, &ops));
    var reader = ops.reader(0);
    const expected = [_]codec_abi.Header{
        .{ .name = "accept", .value = "text/event-stream" },
        .{ .name = "session-id", .value = "00017f80abff10101010101010101010" },
        .{ .name = "originator", .value = "rui" },
    };
    for (expected) |want| {
        const op = (try reader.next()).?;
        try std.testing.expectEqualStrings(want.name, op.header.name);
        try std.testing.expectEqualStrings(want.value, op.header.value);
    }
    while (try reader.next()) |op| try std.testing.expect(op != .header);
}
