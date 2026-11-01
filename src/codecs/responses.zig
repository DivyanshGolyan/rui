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
const Pieces = codec_abi.Pieces;
const Ops = codec_abi.Ops;
const Status = codec_abi.Status;

/// The encoder's state between history elements: whether one was written,
/// since the next input item then takes a comma.
pub const Carry = struct { input_comma: bool };

/// The carry before the first history element.
pub const initial: Carry = .{ .input_comma = false };

/// The request encoder. Beyond its carry, its state lives only within one
/// output item or the tools array. A function call's open and a tool take
/// the most pieces of any item, `codec_abi.max_pieces`.
pub const Encoder = struct {
    carry: Carry,
    /// The open output item's replay rule and the part array it has open.
    omit_reasoning_text: bool = false,
    array: codec_abi.PartArray = .none,
    tool_comma: bool = false,

    pub fn encodeItem(self: *Encoder, header: *const ItemHeader, out: *Pieces) error{Declined}!void {
        out.len = 0;
        switch (header.item) {
            .settings => |*settings| {
                out.literal("{\"model\":\"");
                out.content(0, .json_string_v1);
                out.literal(if (parallelToolCalls(settings.modelName())) envelope(true) else envelope(false));
                if (settings.effort) |effort| out.literal(switch (effort) {
                    inline else => |value| ",\"reasoning\":{\"effort\":\"" ++ @tagName(value) ++ "\"}",
                });
            },
            .instructions => {
                out.literal(",\"instructions\":\"");
                out.content(0, .json_string_v1);
                out.literal("\",\"input\":[");
            },
            .message => |author| {
                self.separateInput(out);
                out.literal(switch (author) {
                    .user => "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"",
                    .instruction => "{\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"",
                });
                // A peer Message's sender is its own leading part, separate
                // from the text the peer wrote.
                if (header.has(1)) {
                    out.content(1, .json_string_v1);
                    out.literal("\"},{\"type\":\"input_text\",\"text\":\"");
                }
                out.content(0, .json_string_v1);
                out.literal("\"}]}");
            },
            // An output item is rebuilt from Rui's form and its provider
            // bags, written canonically: the model receives what it sent.
            .output_open => |output| {
                self.separateInput(out);
                self.omit_reasoning_text = output.omit_reasoning_text;
                self.array = .none;
                switch (output.kind) {
                    .reasoning => out.literal("{\"type\":\"reasoning\""),
                    .compaction => out.literal("{\"type\":\"compaction\""),
                    .message => out.literal(switch (output.phase) {
                        .unphased => "{\"type\":\"message\",\"role\":\"assistant\"",
                        .commentary => "{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"commentary\"",
                        .final_answer => "{\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\"",
                    }),
                    .function_call => {
                        out.literal("{\"type\":\"function_call\",\"name\":\"");
                        out.content(0, .json_string_v1);
                        out.literal("\",\"call_id\":\"");
                        out.content(1, .json_string_v1);
                        out.literal("\",\"arguments\":\"");
                        out.content(2, .json_string_v1);
                        out.literal("\"");
                    },
                }
            },
            .output_part => |part| {
                // Private reasoning text is never replay input.
                if (self.omit_reasoning_text and part.array == .content) return;
                if (self.array == part.array) {
                    out.literal(",");
                } else {
                    if (self.array != .none) out.literal("]");
                    out.literal(if (part.array == .content) ",\"content\":[" else ",\"summary\":[");
                    self.array = part.array;
                }
                if (header.has(0)) {
                    out.literal(switch (part.kind) {
                        .output_text => "{\"type\":\"output_text\",\"text\":\"",
                        .refusal => "{\"type\":\"refusal\",\"refusal\":\"",
                        .summary_text => "{\"type\":\"summary_text\",\"text\":\"",
                        .reasoning_text => "{\"type\":\"reasoning_text\",\"text\":\"",
                        .opaque_block => return error.Declined,
                    });
                    out.content(0, .json_string_v1);
                    if (header.has(1)) {
                        out.literal("\",");
                        out.content(1, .verbatim);
                        out.literal("}");
                    } else out.literal("\"}");
                } else {
                    out.literal("{");
                    out.content(1, .verbatim);
                    out.literal("}");
                }
            },
            .output_close => {
                if (self.array != .none) out.literal("]");
                if (header.has(0)) {
                    out.literal(",");
                    out.content(0, .verbatim);
                }
                out.literal("}");
            },
            .tool_result => {
                self.separateInput(out);
                out.literal("{\"type\":\"function_call_output\",\"call_id\":\"");
                out.content(0, .json_string_v1);
                out.literal("\",\"output\":\"");
                out.content(1, .json_string_v1);
                out.literal("\"}");
            },
            .history_end => {},
            .compaction_trigger => {
                self.separateInput(out);
                out.literal("{\"type\":\"compaction_trigger\"}");
            },
            .tools_start => out.literal("],\"tools\":["),
            .tool => {
                if (self.tool_comma) out.literal(",");
                self.tool_comma = true;
                out.literal("{\"type\":\"function\",\"name\":\"");
                out.content(0, .json_string_v1);
                out.literal("\",\"description\":\"");
                out.content(1, .json_string_v1);
                out.literal("\",\"strict\":true,\"parameters\":");
                out.content(2, .verbatim);
                out.literal("}");
            },
            // The tools array closes here, after its last tool.
            .text_format => if (header.has(0)) {
                out.literal("],\"text\":{\"verbosity\":\"low\",\"format\":{\"type\":\"json_schema\",\"name\":\"rui_output\",\"strict\":true,\"schema\":");
                out.content(0, .verbatim);
                out.literal("}}");
            } else out.literal("],\"text\":{\"verbosity\":\"low\"}"),
            .request_end => out.literal("}"),
        }
    }

    /// An input item after another takes a comma.
    fn separateInput(self: *Encoder, out: *Pieces) void {
        if (self.carry.input_comma) out.literal(",");
        self.carry.input_comma = true;
    }
};

/// The request headers this codec writes, by name.
pub const RequestHeader = enum(u8) { accept, @"session-id", originator };

/// Codex routes a Session's requests by its session id.
pub fn requestHeaders(settings: *const codec_abi.Settings, out: *codec_abi.Headers) void {
    out.count = 0;
    out.add(RequestHeader.accept, "text/event-stream");
    out.add(RequestHeader.@"session-id", &std.fmt.bytesToHex(settings.session_affinity, .lower));
    out.add(RequestHeader.originator, "rui");
}

/// Reads an HTTP error body. A Responses body is one JSON object whose
/// `error` object names the failure: its `code` (and, for a quota, its
/// `resets_at`), its `type` standing in for a missing code in the report,
/// and its `message`, else a bare `detail`; a body without `error` reports
/// only its own `message` or `detail`. Only a whole valid body and members
/// that appear once count. The reader holds the state for any body size,
/// and the report is named by range, so nothing of the body is buffered.
pub const Classifier = struct {
    reader: json.Reader = undefined,
    /// The named member being read, of the body and of its error object;
    /// null for any other.
    outer: ?Outer,
    inner: ?Inner,
    /// Whether the body's `error` member is an object.
    error_object: bool,
    envelope: std.enums.EnumArray(Outer, Member),
    failure: std.enums.EnumArray(Inner, Member),
    /// The error object's code, when it is a string of at most
    /// max_code_bytes; empty otherwise.
    code: [codec_abi.max_code_bytes]u8 = undefined,
    code_length: u8,
    /// The error object's `resets_at`, when it is a plain integer.
    resets_at: ?u64,

    const Outer = enum { @"error", message, detail };
    const Inner = enum { code, type, message, detail, resets_at };

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
            .outer = null,
            .inner = null,
            .error_object = false,
            .envelope = .initFill(.{}),
            .failure = .initFill(.{}),
            .code_length = 0,
            .resets_at = null,
        };
        self.reader.init();
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
            1 => self.outer = std.meta.stringToEnum(Outer, name),
            2 => if (self.inError()) {
                self.inner = std.meta.stringToEnum(Inner, name);
            },
            else => {},
        }
    }

    pub fn begin(self: *Classifier, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        _ = reader;
        switch (depth) {
            1 => if (self.outer) |outer| {
                start(self.envelope.getPtr(outer));
                if (outer == .@"error") self.error_object = kind == .object;
            },
            2 => if (self.inError()) if (self.inner) |inner| {
                start(self.failure.getPtr(inner));
                if (inner == .code) self.code_length = 0;
                if (inner == .resets_at) self.resets_at = null;
            },
            else => {},
        }
    }

    pub fn end(self: *Classifier, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        switch (depth) {
            1 => if (kind == .string) if (self.outer) |outer| {
                self.envelope.getPtr(outer).set(reader.string());
            },
            2 => if (self.inError()) if (self.inner) |inner| switch (kind) {
                .string => {
                    self.failure.getPtr(inner).set(reader.string());
                    if (inner == .code) if (reader.text()) |text| {
                        @memcpy(self.code[0..text.len], text);
                        self.code_length = @intCast(text.len);
                    };
                },
                .number => if (inner == .resets_at) {
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

test "an encoder resumed from a carry separates its next input item only after an earlier one" {
    const header: ItemHeader = .{ .item = .tool_result, .handles = 0b11 };
    var pieces: Pieces = .{ .len = 0 };
    var first: Encoder = .{ .carry = initial };
    try first.encodeItem(&header, &pieces);
    try std.testing.expect(!std.mem.eql(u8, pieces.items[0].literal, ","));
    // A fresh encoder given only the carry that element ended in.
    var next: Encoder = .{ .carry = first.carry };
    try next.encodeItem(&header, &pieces);
    try std.testing.expectEqualStrings(",", pieces.items[0].literal);
}

test "every item at its longest fits max_pieces and names only handles it has" {
    // Every item the Host can give, with each handle set it can give that
    // item, from every state the encoder can be in before it.
    const Case = struct { item: codec_abi.Item, handles: []const u8 };
    var cases: [64]Case = undefined;
    var count: usize = 0;
    for ([_]?codec_abi.Effort{null} ++ std.enums.values(codec_abi.Effort)) |effort| {
        cases[count] = .{ .item = .{ .settings = .{ .effort = effort, .session_affinity = @splat(0xff), .model_length = 0 } }, .handles = &.{0b1} };
        count += 1;
    }
    for (std.enums.values(codec_abi.Author)) |author| {
        cases[count] = .{ .item = .{ .message = author }, .handles = &.{ 0b01, 0b11 } };
        count += 1;
    }
    for (std.enums.values(codec_abi.OutputKind)) |kind| for (std.enums.values(codec_abi.Phase)) |phase| for ([_]bool{ false, true }) |omit| {
        cases[count] = .{ .item = .{ .output_open = .{ .kind = kind, .phase = phase, .omit_reasoning_text = omit } }, .handles = if (kind == .function_call) &.{0b111} else &.{0} };
        count += 1;
    };
    for ([_]codec_abi.PartArray{ .content, .summary }) |array| for (std.enums.values(codec_abi.PartKind)) |kind| {
        cases[count] = .{ .item = .{ .output_part = .{ .array = array, .kind = kind } }, .handles = if (kind == .opaque_block) &.{0b10} else &.{ 0b01, 0b11 } };
        count += 1;
    };
    for ([_]Case{
        .{ .item = .instructions, .handles = &.{0b1} },
        .{ .item = .output_close, .handles = &.{ 0, 0b1 } },
        .{ .item = .tool_result, .handles = &.{0b11} },
        .{ .item = .history_end, .handles = &.{0} },
        .{ .item = .compaction_trigger, .handles = &.{0} },
        .{ .item = .tools_start, .handles = &.{0} },
        .{ .item = .tool, .handles = &.{0b111} },
        .{ .item = .text_format, .handles = &.{ 0, 0b1 } },
        .{ .item = .request_end, .handles = &.{0} },
    }) |case| {
        cases[count] = case;
        count += 1;
    }
    var longest: u8 = 0;
    for (cases[0..count]) |case| for (case.handles) |handles| {
        for ([_]bool{ false, true }) |comma| for ([_]bool{ false, true }) |omit| for (std.enums.values(codec_abi.PartArray)) |array| {
            var encoder: Encoder = .{ .carry = .{ .input_comma = comma }, .tool_comma = comma, .omit_reasoning_text = omit, .array = array };
            const header: ItemHeader = .{ .item = case.item, .handles = handles };
            var pieces: Pieces = .{ .len = 0 };
            try encoder.encodeItem(&header, &pieces);
            longest = @max(longest, pieces.len);
            for (pieces.slice()) |piece| switch (piece) {
                .literal => |bytes| try std.testing.expect(bytes.len != 0),
                .content => |content| try std.testing.expect(header.has(content.handle)),
            };
        };
    };
    try std.testing.expectEqual(codec_abi.max_pieces, longest);
}

test "the request headers ask for the stream, the Session's id and Rui as originator" {
    const settings: codec_abi.Settings = .{ .effort = null, .session_affinity = .{ 0x00, 0x01, 0x7f, 0x80, 0xab, 0xff } ++ @as([10]u8, @splat(0x10)), .model_length = 0 };
    var headers: codec_abi.Headers = .{ .count = 0 };
    requestHeaders(&settings, &headers);
    const expected = [_]struct { RequestHeader, []const u8 }{
        .{ .accept, "text/event-stream" },
        .{ .@"session-id", "00017f80abff10101010101010101010" },
        .{ .originator, "rui" },
    };
    try std.testing.expectEqual(@as(u8, expected.len), headers.count);
    for (expected, 0..) |want, index| {
        try std.testing.expectEqual(want[0], @as(RequestHeader, @fromBackingInt(@intCast(headers.names[index]))));
        try std.testing.expectEqualStrings(want[1], headers.value(index));
    }
}
