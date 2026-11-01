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
    reader: json.Reader = undefined,
    /// The named member being read, of the body and of its error object;
    /// null for any other.
    outer: ?Outer,
    inner: ?Inner,
    /// Whether the body's `error` member is an object.
    error_object: bool,
    envelope: std.EnumArray(Outer, Member),
    failure: std.EnumArray(Inner, Member),
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

// ------------------------------------------------------------- interpret

const Record = codec_abi.Record;
const Reason = codec_abi.Reason;

/// A verdict while it is being reached, as the error that `Reason` names.
const Failure = error{
    ContradictoryProviderOutput,
    LateProviderOutput,
    ProviderConnectionClosed,
    MissingProviderField,
    DuplicateJsonField,
    ExpectedJsonString,
    ProviderValueTooLong,
    InvalidProviderIndex,
    TrailingJson,
    Overflow,
    UnexpectedJsonDelimiter,
    UnsupportedEventType,
    UnsupportedItemType,
    EmptyProviderIdentity,
    UnfinishedProviderOutputItem,
    UnsupportedResponseStatus,
    IncompleteProviderOutput,
    TemporaryProviderFailure,
    ContextOverflow,
    ReportedProviderFailure,
} || Judge.Incompatibility || json.Error;

comptime {
    // Every reason is a failure and every failure a reason.
    @setEvalBranchQuota(100_000);
    for (@typeInfo(Reason).@"enum".field_names) |name| std.debug.assert(@field(Failure, codec_abi.reasonName(@field(Reason, name))) != error.OutOfMemory);
    _ = reasonOf;
}

fn reasonOf(err: Failure) Reason {
    @setEvalBranchQuota(100_000);
    switch (err) {
        inline else => |known| inline for (@typeInfo(Reason).@"enum".field_names) |name| {
            if (comptime std.mem.eql(u8, codec_abi.reasonName(@field(Reason, name)), @errorName(known))) return @field(Reason, name);
        } else @compileError("no reason names " ++ @errorName(known)),
    }
}

/// Strings the interpreter compares whole.
const Word = enum {
    @"response.output_item.added",
    @"response.output_item.done",
    @"response.completed",
    @"error",
    @"response.failed",
    @"response.incomplete",
    failed,
    incomplete,
    context_length_exceeded,
    reasoning,
    compaction,
    function_call,
    message,
    completed,
    assistant,
    commentary,
    partial_answer,
    final_answer,
    direct,
    output_text,
    refusal,
    reasoning_text,
    summary_text,
    url_citation,

    fn of(reader: *const json.Reader) ?Word {
        return std.meta.stringToEnum(Word, reader.text() orelse return null);
    }

    fn kind(word: ?Word) ?codec_abi.OutputKind {
        return switch (word orelse return null) {
            .reasoning => .reasoning,
            .compaction => .compaction,
            .function_call => .function_call,
            .message => .message,
            else => null,
        };
    }
};

const Shape = enum(u8) { absent, string, object, array, null_value, false_value, true_value, number };

fn shapeOf(reader: *const json.Reader, kind: json.Kind) Shape {
    return switch (kind) {
        .object => .object,
        .array => .array,
        .string => .string,
        .number => .number,
        .literal => switch (reader.literalValue()) {
            .true_value => .true_value,
            .false_value => .false_value,
            .null_value => .null_value,
        },
    };
}

/// Where a value ends, one past its last byte, in `end`: a number ends at
/// the byte after it, which the reader is reading.
fn valueEnd(reader: *const json.Reader, kind: json.Kind) u64 {
    return if (kind == .number) reader.offset else reader.offset + 1;
}

/// The longest string compared with a known word or code.
const max_word_bytes = 256;

/// One output item's grammar, as acceptance has always judged it: the first
/// rule an item breaks, in rule order, or its replay rule. A block's meaning
/// depends on its item's type, which can arrive after the block, so each
/// block keeps one result per reading and the item consults the one it
/// needs. Only the item, its block arrays, blocks, annotation arrays and
/// annotations carry rules; anything deeper is followed by depth alone.
const Judge = struct {
    operation: codec_abi.Operation,
    frames: [max_frames]Frame,
    /// Open judged containers.
    depth: u8,
    /// Open containers below the judged ones.
    ignored: u8,
    result: Value,
    item_kind: ?codec_abi.OutputKind,

    const max_frames = 5;

    const Name = enum { type, id, status, role, phase, internal_chat_message_metadata_passthrough, content, text, encrypted_content, summary, name, call_id, arguments, caller, async, namespace, encrypted_function_args, refusal, annotations, cell_id, executed_tool_calls, tool_calls_complete };
    const name_count = @typeInfo(Name).@"enum".field_names.len;

    const Reading = enum { output, reasoning, summary };
    const readings = .{ Reading.output, .reasoning, .summary };
    const Readings = struct { all: bool = false, output: bool = false, reasoning: bool = false, summary: bool = false };

    const Incompatibility = error{
        DuplicateJsonField,
        MissingProviderField,
        ExpectedJsonString,
        ProviderValueTooLong,
        EmptyProviderIdentity,
        UnsupportedItemStatus,
        ContinuationUnavailable,
        UnexpectedJsonDelimiter,
        UnsupportedContentBlock,
        UnsupportedReasoningBlock,
        UnsupportedItemType,
        UnsupportedReasoningText,
        UnsupportedProviderOutput,
        UnsupportedAsyncCall,
        InvalidJsonLiteral,
        UnsupportedCallControl,
        UnsupportedMessageRole,
        UnsupportedMessagePhase,
        MalformedProviderOutput,
        UnsupportedAnnotation,
        UnsupportedCaller,
        UnsupportedMetadataAuthority,
    };

    const Value = struct {
        shape: Shape = .absent,
        word: ?Word = null,
        length: u64 = 0,
        duplicate: bool = false,
        // The first rule broken, in rule order: under every reading, then
        // under each one.
        failure: ?Incompatibility = null,
        output_failure: ?Incompatibility = null,
        reasoning_failure: ?Incompatibility = null,
        summary_failure: ?Incompatibility = null,
        /// Whether a field this value's meaning consumes is a duplicate,
        /// under every reading or under each one.
        ambiguous: Readings = .{},

        fn is(self: Value, word: Word) bool {
            return self.shape == .string and self.word == word;
        }

        fn failureAs(self: Value, comptime reading: Reading) ?Incompatibility {
            return self.failure orelse @field(self, @tagName(reading) ++ "_failure");
        }

        fn ambiguousAs(self: Value, comptime reading: Reading) bool {
            return self.ambiguous.all or @field(self.ambiguous, @tagName(reading));
        }

        fn itemKind(self: Value) ?codec_abi.OutputKind {
            return if (self.shape == .string) Word.kind(self.word) else null;
        }
    };

    const Kind = enum { item, block, annotation, caller, metadata, blocks, annotations, ignored };

    const Frame = struct {
        kind: Kind,
        object: bool,
        key: ?Name,
        wants_key: bool,
        fields: [name_count]Value,
        aggregate: Value,

        fn get(self: *const Frame, comptime name: Name) Incompatibility!Value {
            const value = self.fields[@backingInt(name)];
            if (value.duplicate) return error.DuplicateJsonField;
            return value;
        }

        fn string(self: *const Frame, comptime name: Name) Incompatibility!Value {
            const value = try self.get(name);
            return switch (value.shape) {
                .string => value,
                .absent => error.MissingProviderField,
                else => error.ExpectedJsonString,
            };
        }

        /// A string compared with known words, readable only when short.
        fn word(self: *const Frame, comptime name: Name) Incompatibility!Value {
            const value = try self.string(name);
            if (value.length > max_word_bytes) return error.ProviderValueTooLong;
            return value;
        }

        fn identity(self: *const Frame, comptime name: Name) Incompatibility!void {
            if ((try self.string(name)).length == 0) return error.EmptyProviderIdentity;
        }

        fn completed(self: *const Frame) Incompatibility!void {
            if ((try self.get(.status)).shape == .absent) return;
            if (!(try self.word(.status)).is(.completed)) return error.UnsupportedItemStatus;
        }

        fn encrypted(self: *const Frame) Incompatibility!void {
            const value = try self.get(.encrypted_content);
            switch (value.shape) {
                .absent => return error.ContinuationUnavailable,
                .string => if (value.length == 0) return error.ContinuationUnavailable,
                else => return error.ExpectedJsonString,
            }
        }

        /// A nested array the reading consumes: when present, an array whose
        /// elements all satisfy that reading.
        fn blocks(self: *const Frame, comptime name: Name, comptime reading: Reading) Incompatibility!void {
            const value = try self.get(name);
            if (value.shape == .absent) return;
            if (value.shape != .array) return error.UnexpectedJsonDelimiter;
            if (value.failureAs(reading)) |err| return err;
        }

        fn consumesDuplicate(self: *const Frame, comptime field_names: []const Name, comptime reading: ?Reading) bool {
            inline for (field_names) |name| {
                const value = self.fields[@backingInt(name)];
                if (value.duplicate) return true;
                if (if (reading) |consumed| value.ambiguousAs(consumed) else value.ambiguous.all) return true;
            }
            return false;
        }
    };

    /// The fields one object's rules consume: plain fields, and nested arrays
    /// read under one reading. `judge` looks up only these, enforced at
    /// compile time, and `ambiguity` finds a consumed duplicate among them.
    const Consumed = struct {
        plain: []const Name = &.{},
        nested: []const struct { Name, Reading } = &.{},

        fn join(comptime a: Consumed, comptime b: Consumed) Consumed {
            return .{ .plain = a.plain ++ b.plain, .nested = a.nested ++ b.nested };
        }

        fn reads(comptime self: Consumed, comptime name: Name, comptime reading: ?Reading) bool {
            if (reading == null) for (self.plain) |field| if (field == name) return true;
            for (self.nested) |field| if (field[0] == name and (reading == null or field[1] == reading.?)) return true;
            return false;
        }

        fn duplicateIn(comptime self: Consumed, frame: *const Frame) bool {
            if (frame.consumesDuplicate(self.plain, null)) return true;
            inline for (self.nested) |field| if (frame.consumesDuplicate(&.{field[0]}, field[1])) return true;
            return false;
        }
    };

    const item_fields: Consumed = .{ .plain = &.{ .type, .id, .status, .internal_chat_message_metadata_passthrough } };
    fn kindFields(comptime kind: codec_abi.OutputKind) Consumed {
        return item_fields.join(switch (kind) {
            .reasoning => .{ .plain = &.{ .text, .encrypted_content }, .nested = &.{ .{ .summary, .summary }, .{ .content, .reasoning } } },
            .compaction => .{ .plain = &.{.encrypted_content} },
            .function_call => .{ .plain = &.{ .name, .call_id, .arguments, .caller, .async, .namespace, .encrypted_function_args } },
            .message => .{ .plain = &.{ .role, .phase }, .nested = &.{.{ .content, .output }} },
        });
    }
    const type_fields: Consumed = .{ .plain = &.{.type} };
    const refusal_fields: Consumed = .{ .plain = &.{.refusal} };
    const output_text_fields: Consumed = .{ .plain = &.{.text}, .nested = &.{.{ .annotations, .output }} };
    const text_fields: Consumed = .{ .plain = &.{.text} };
    const metadata_fields: Consumed = .{ .plain = &.{ .cell_id, .executed_tool_calls, .tool_calls_complete } };

    /// A frame's lookups, limited to the fields `consumed` names.
    fn Rules(comptime consumed: Consumed) type {
        return struct {
            frame: *const Frame,
            const Self = @This();

            fn require(comptime name: Name, comptime reading: ?Reading) void {
                if (!comptime consumed.reads(name, reading)) @compileError("a rule reads " ++ @tagName(name) ++ ", which its fields table does not list");
            }
            fn get(self: Self, comptime name: Name) Incompatibility!Value {
                require(name, null);
                return self.frame.get(name);
            }
            fn string(self: Self, comptime name: Name) Incompatibility!Value {
                require(name, null);
                return self.frame.string(name);
            }
            fn word(self: Self, comptime name: Name) Incompatibility!Value {
                require(name, null);
                return self.frame.word(name);
            }
            fn identity(self: Self, comptime name: Name) Incompatibility!void {
                require(name, null);
                return self.frame.identity(name);
            }
            fn completed(self: Self) Incompatibility!void {
                require(.status, null);
                return self.frame.completed();
            }
            fn encrypted(self: Self) Incompatibility!void {
                require(.encrypted_content, null);
                return self.frame.encrypted();
            }
            fn blocks(self: Self, comptime name: Name, comptime reading: Reading) Incompatibility!void {
                require(name, reading);
                return self.frame.blocks(name, reading);
            }
        };
    }

    /// Readies the judge for one item. The frames are written as they open.
    fn reset(self: *Judge, operation: codec_abi.Operation) void {
        self.operation = operation;
        self.depth = 0;
        self.ignored = 0;
        self.result = .{};
        self.item_kind = null;
    }

    /// A key of the innermost open container.
    fn key(self: *Judge, reader: *const json.Reader) void {
        if (self.ignored != 0) return;
        const frame = &self.frames[self.depth - 1];
        frame.key = std.meta.stringToEnum(Name, reader.text() orelse "");
        frame.wants_key = false;
    }

    fn begin(self: *Judge, kind: json.Kind) void {
        if (kind != .object and kind != .array) return;
        if (self.ignored != 0) {
            self.ignored += 1;
            return;
        }
        const object = kind == .object;
        const child = self.childKind(object);
        if (child == .ignored and self.depth != 0) {
            self.ignored = 1;
            return;
        }
        const frame = &self.frames[self.depth];
        frame.kind = child;
        frame.object = object;
        frame.key = null;
        frame.wants_key = true;
        frame.fields = @splat(.{});
        frame.aggregate = .{ .shape = .array };
        self.depth += 1;
    }

    fn end(self: *Judge, reader: *const json.Reader, kind: json.Kind) void {
        switch (kind) {
            .object, .array => {
                if (self.ignored != 0) {
                    self.ignored -= 1;
                    if (self.ignored == 0) self.accept(.{ .shape = shapeOf(reader, kind) });
                    return;
                }
                self.depth -= 1;
                self.accept(self.finishFrame(&self.frames[self.depth]));
            },
            else => {
                if (self.ignored != 0) return;
                var value: Value = .{ .shape = shapeOf(reader, kind) };
                if (kind == .string) {
                    value.length = reader.decoded;
                    value.word = Word.of(reader);
                }
                self.accept(value);
            },
        }
    }

    /// The item's verdict once its last byte is read.
    fn verdict(self: *const Judge) Incompatibility!bool {
        if (self.result.shape != .object) return error.UnexpectedJsonDelimiter;
        if (self.result.failure) |err| return err;
        std.debug.assert(!self.result.ambiguous.all);
        return self.replaysReasoningText();
    }

    // Other kinds leave `content` open, duplicates included.
    fn replaysReasoningText(self: *const Judge) bool {
        if (self.item_kind != .reasoning) return false;
        const content = self.frames[0].get(.content) catch unreachable;
        return content.shape == .array and content.length != 0;
    }

    /// After a compatible message is judged, the phase that selects its
    /// answer.
    fn answerPhase(self: *const Judge) codec_abi.Phase {
        if (self.item_kind != .message) return .unphased;
        const phase = self.frames[0].get(.phase) catch unreachable;
        if (phase.is(.commentary) or phase.is(.partial_answer)) return .commentary;
        if (phase.is(.final_answer)) return .final_answer;
        return .unphased;
    }

    fn accept(self: *Judge, value: Value) void {
        if (self.depth == 0) {
            self.result = value;
            return;
        }
        const frame = &self.frames[self.depth - 1];
        if (frame.object) {
            if (frame.key) |name| {
                const field = &frame.fields[@backingInt(name)];
                const duplicate = field.shape != .absent;
                field.* = value;
                field.duplicate = duplicate;
            }
            frame.wants_key = true;
            frame.key = null;
        } else {
            // Elements are judged in order: the first failure stands.
            frame.aggregate.length += 1;
            inline for (readings) |reading| {
                const prior = &@field(frame.aggregate, @tagName(reading) ++ "_failure");
                if (prior.* == null) prior.* = if (value.shape != .object) error.UnexpectedJsonDelimiter else value.failureAs(reading);
                if (value.ambiguousAs(reading)) @field(frame.aggregate.ambiguous, @tagName(reading)) = true;
            }
        }
    }

    fn childKind(self: *const Judge, object: bool) Kind {
        if (self.depth == 0) return if (object) .item else .ignored;
        const parent = &self.frames[self.depth - 1];
        if (!parent.object) return switch (parent.kind) {
            .blocks => if (object) .block else .ignored,
            .annotations => if (object) .annotation else .ignored,
            else => .ignored,
        };
        const name = parent.key orelse return .ignored;
        if (parent.kind == .item) {
            if (object and name == .caller) return .caller;
            if (object and name == .internal_chat_message_metadata_passthrough) return .metadata;
            if (!object and (name == .content or name == .summary)) return .blocks;
        }
        if (parent.kind == .block and !object and name == .annotations) return .annotations;
        return .ignored;
    }

    fn finishFrame(self: *Judge, frame: *const Frame) Value {
        if (!frame.object) return frame.aggregate;
        var result: Value = .{ .shape = .object, .ambiguous = ambiguity(frame) };
        self.judge(frame, &result) catch |err| {
            result.failure = err;
        };
        return result;
    }

    // A consumed duplicate, wherever it stands among the rules.
    fn ambiguity(frame: *const Frame) Readings {
        const declared = frame.fields[@backingInt(Name.type)];
        return switch (frame.kind) {
            .item => .{ .all = item_fields.duplicateIn(frame) or if (declared.itemKind()) |kind| switch (kind) {
                inline else => |known| (comptime kindFields(known)).duplicateIn(frame),
            } else false },
            .block => .{
                .all = type_fields.duplicateIn(frame),
                .output = if (declared.is(.refusal))
                    refusal_fields.duplicateIn(frame)
                else
                    declared.is(.output_text) and output_text_fields.duplicateIn(frame),
                .reasoning = declared.is(.reasoning_text) and text_fields.duplicateIn(frame),
                .summary = declared.is(.summary_text) and text_fields.duplicateIn(frame),
            },
            .annotation, .caller => .{ .all = type_fields.duplicateIn(frame) },
            .metadata => .{ .all = metadata_fields.duplicateIn(frame) },
            else => .{},
        };
    }

    // Each object's rules run in a fixed order; the first one broken is its
    // failure.
    fn judge(self: *Judge, frame: *const Frame, result: *Value) Incompatibility!void {
        switch (frame.kind) {
            .item => {
                const item = Rules(item_fields){ .frame = frame };
                _ = try item.word(.type);
                try item.identity(.id);
                const metadata = try item.get(.internal_chat_message_metadata_passthrough);
                if (metadata.shape != .absent) {
                    if (metadata.shape != .object) return error.UnexpectedJsonDelimiter;
                    if (metadata.failure) |err| return err;
                }
                const kind = (try item.get(.type)).itemKind() orelse return error.UnsupportedItemType;
                self.item_kind = kind;
                switch (kind) {
                    .reasoning => {
                        const rules = Rules(kindFields(.reasoning)){ .frame = frame };
                        try rules.completed();
                        if ((try rules.get(.text)).shape != .absent) return error.UnsupportedReasoningText;
                        try rules.encrypted();
                        try rules.blocks(.summary, .summary);
                        try rules.blocks(.content, .reasoning);
                    },
                    .compaction => {
                        const rules = Rules(kindFields(.compaction)){ .frame = frame };
                        if (self.operation != .compaction) return error.UnsupportedProviderOutput;
                        try rules.completed();
                        try rules.encrypted();
                    },
                    .function_call => {
                        const rules = Rules(kindFields(.function_call)){ .frame = frame };
                        if (self.operation == .compaction) return error.UnsupportedProviderOutput;
                        try rules.completed();
                        const caller = try rules.get(.caller);
                        switch (caller.shape) {
                            .absent, .null_value => {},
                            .object => if (caller.failure) |err| return err,
                            else => return error.UnexpectedJsonDelimiter,
                        }
                        switch ((try rules.get(.async)).shape) {
                            .absent, .null_value, .false_value => {},
                            .true_value => return error.UnsupportedAsyncCall,
                            else => return error.InvalidJsonLiteral,
                        }
                        inline for (.{ .namespace, .encrypted_function_args }) |name| {
                            const value = try rules.get(name);
                            switch (value.shape) {
                                .absent, .null_value => {},
                                .string => if (value.length != 0) return error.UnsupportedCallControl,
                                else => return error.ExpectedJsonString,
                            }
                        }
                        inline for (.{ .name, .call_id }) |name| try rules.identity(name);
                        _ = try rules.string(.arguments);
                    },
                    .message => {
                        const rules = Rules(kindFields(.message)){ .frame = frame };
                        try rules.completed();
                        if (!(try rules.word(.role)).is(.assistant)) return error.UnsupportedMessageRole;
                        const phase = try rules.get(.phase);
                        if (phase.shape != .absent and phase.shape != .null_value) {
                            _ = try rules.word(.phase);
                            if (!phase.is(.commentary) and !phase.is(.partial_answer) and !phase.is(.final_answer)) return error.UnsupportedMessagePhase;
                        }
                        const content = try rules.get(.content);
                        if (content.shape == .absent) return error.MissingProviderField;
                        try rules.blocks(.content, .output);
                        if (content.length == 0) return error.MalformedProviderOutput;
                    },
                }
            },
            .block => {
                const kind = try (Rules(type_fields){ .frame = frame }).word(.type);
                outputBlock(frame, kind) catch |err| {
                    result.output_failure = err;
                };
                textBlock(frame, kind, .reasoning_text) catch |err| {
                    result.reasoning_failure = err;
                };
                textBlock(frame, kind, .summary_text) catch |err| {
                    result.summary_failure = err;
                };
            },
            .annotation => {
                if (!(try (Rules(type_fields){ .frame = frame }).word(.type)).is(.url_citation)) result.output_failure = error.UnsupportedAnnotation;
            },
            .caller => {
                const rules = Rules(type_fields){ .frame = frame };
                if ((try rules.get(.type)).shape == .absent) return error.UnsupportedCaller;
                if (!(try rules.word(.type)).is(.direct)) return error.UnsupportedCaller;
            },
            .metadata => {
                const rules = Rules(metadata_fields){ .frame = frame };
                inline for (metadata_fields.plain) |name| {
                    if ((try rules.get(name)).shape != .absent) return error.UnsupportedMetadataAuthority;
                }
            },
            else => {},
        }
    }

    fn outputBlock(frame: *const Frame, kind: Value) Incompatibility!void {
        if (kind.is(.refusal)) {
            _ = try (Rules(refusal_fields){ .frame = frame }).string(.refusal);
            return;
        }
        if (!kind.is(.output_text)) return error.UnsupportedContentBlock;
        const rules = Rules(output_text_fields){ .frame = frame };
        try rules.blocks(.annotations, .output);
        _ = try rules.string(.text);
    }

    // Reasoning and summary blocks retain annotations without interpreting
    // them.
    fn textBlock(frame: *const Frame, kind: Value, comptime expected: Word) Incompatibility!void {
        if (!kind.is(expected)) return error.UnsupportedReasoningBlock;
        _ = try (Rules(text_fields){ .frame = frame }).string(.text);
    }
};

/// What an event is, by its type.
const EventType = enum { added, done, completed, error_event, failed, incomplete, unsupported, other };

/// Names the interpreter follows outside an item's grammar.
const Key = enum { type, output_index, item, response, code, @"error", message, detail, status, id, model, output, usage, incomplete_details, reason, input_tokens, output_tokens, input_tokens_details, cached_tokens, element, other };

const EventKey = enum { type, output_index, item, response, code, @"error", message, detail };
const ReportKey = enum { code, type, message, detail };
const ResponseKey = enum { status, id, model, output, usage, @"error", incomplete_details };
const IdentityKey = enum { type, id };
const UsageKey = enum { input_tokens, output_tokens, input_tokens_details };

fn subset(comptime T: type, key: Key) ?T {
    return std.meta.stringToEnum(T, @tagName(key));
}

/// What one named value was, as the envelope's rules read it.
const Named = struct {
    /// How often it appears, counting no further than a duplicate.
    count: u2 = 0,
    shape: Shape = .absent,
    word: ?Word = null,
    decoded: u64 = 0,
    /// A string's contents, or the value whole, as event offsets.
    range: json.Range = .{ .start = 0, .length = 0 },
    digits: json.Digits = .plain,
    integer: ?u64 = null,

    fn begin(self: *Named, reader: *const json.Reader) void {
        self.count +|= 1;
        self.shape = .absent;
        self.word = null;
        self.range = .{ .start = reader.offset, .length = 0 };
    }

    fn end(self: *Named, reader: *const json.Reader, kind: json.Kind) void {
        self.shape = shapeOf(reader, kind);
        switch (kind) {
            .string => {
                self.range = reader.string();
                self.decoded = reader.decoded;
                self.word = Word.of(reader);
            },
            .number => {
                self.digits = reader.digits;
                self.integer = reader.integer;
                self.range.length = reader.offset - self.range.start;
            },
            else => self.range.length = valueEnd(reader, kind) - self.range.start,
        }
    }

    /// The value, unless it appears more than once.
    fn get(self: *const Named) Failure!?*const Named {
        return switch (self.count) {
            0 => null,
            1 => self,
            else => error.DuplicateJsonField,
        };
    }

    fn required(self: *const Named) Failure!*const Named {
        return try self.get() orelse error.MissingProviderField;
    }

    /// A string short enough to compare with a word.
    fn compared(self: *const Named) Failure!?Word {
        if (self.shape != .string) return error.ExpectedJsonString;
        if (self.decoded > max_word_bytes) return error.ProviderValueTooLong;
        return self.word;
    }

    /// A count of tokens, if it is a whole number SQLite can hold.
    fn tokens(self: ?*const Named) ?u64 {
        const member = self orelse return null;
        if (member.shape != .number or member.digits != .plain) return null;
        return if (member.integer.? > std.math.maxInt(i64)) null else member.integer.?;
    }
};

/// The decoded start of a provider code, kept to match and to name.
const Code = struct {
    bytes: [codec_abi.max_code_bytes]u8 = undefined,
    length: u8 = 0,

    fn keep(self: *Code, reader: *const json.Reader) void {
        const text = reader.text() orelse "";
        const kept = text[0..@min(text.len, self.bytes.len)];
        @memcpy(self.bytes[0..kept.len], kept);
        self.length = @intCast(kept.len);
    }
};

/// Bytes of a span the Host has not been given yet.
const Cursor = struct {
    open: bool = false,
    cursor: u64 = 0,
};

/// Reads a Responses event stream, one pass per event: the envelope
/// scanner finds each event's type and hands an output item to the item
/// judge, while the split names the item's parts, bag members and call
/// fields to the Host as it reads them. Only the first value of a member
/// that appears more than once is followed; the verdict refuses the
/// duplicate.
pub const Interpreter = struct {
    reader: json.Reader,
    operation: codec_abi.Operation,
    /// The window's records, while a window is read.
    ops: *Ops,
    /// A record did not fit, which the reserve rules out.
    overflowed: bool,

    completed: bool,
    done_marker: bool,
    item_count: u64,
    added_active: bool,

    in_event: bool,
    event_start: u64,
    /// Where the next window must begin.
    position: u64,
    /// The bytes of `[DONE]` the event has matched; past its length once
    /// the event differs.
    done_match: u8,
    /// Why the event's data is not JSON, once the reader found it.
    syntax: ?json.Error,
    /// The event's type, when a first pass found it only after a value
    /// that needs it, so this pass reads the event again knowing it.
    known: ?EventType,
    /// Where to read again from, once a value's meaning arrived after it.
    seek: ?Seek,
    scan: Scan,
    judge: Judge,
    split: Split,
    raw: std.EnumArray(codec_abi.Span, Cursor),
    string_field: codec_abi.Field,
    string_span: Cursor,
    /// The judge's open frames outside the block that may be read again.
    block_judge_depth: u8,

    const done_marker_bytes = "[DONE]";
    /// Room each byte keeps in `Ops`: the most records one byte gives, and
    /// a flush of every open span with the `need` after it.
    const reserve = 160;

    const Seek = struct { level: enum { event, item, block }, offset: u64 };

    /// One pass over one event.
    const Scan = struct {
        type: ?EventType,
        /// A value that needs the type began before it.
        replay: bool,
        path: [6]Key,
        outer: std.EnumArray(EventKey, Named),
        nested: std.EnumArray(ReportKey, Named),
        response: std.EnumArray(ResponseKey, Named),
        response_error: std.EnumArray(ReportKey, Named),
        details_reason: Named,
        identity: std.EnumArray(IdentityKey, Named),
        terminal: std.EnumArray(IdentityKey, Named),
        usage: std.EnumArray(UsageKey, Named),
        cached: Named,
        codes: std.EnumArray(enum { event, nested, response }, Code),
        /// How the item is read: judged in a done event, for its identity
        /// in an added event, and for its kind alone before the event's
        /// type is known.
        item_mode: enum { none, judged, identity, kind },
    };

    /// An item's records, as the split gives them.
    const Split = struct {
        /// False once the item is known to fail, so its records are moot.
        live: bool,
        kind: ?codec_abi.OutputKind,
        /// This pass reads the item again, its kind known from the start.
        replaying: bool,
        /// A member whose meaning needs the kind came before it.
        replay: bool,
        start: u64,
        types: u2,
        /// Bag members, and the id's contents, before the kind arrived.
        pending: Pending,
        member: ItemMember,
        key_start: u64,
        phase: codec_abi.Phase,
        /// The neutral array whose blocks are read, and how many it has.
        array: codec_abi.PartArray,
        elements: u64,
        block: Block,
    };

    const Pending = struct {
        members: [2]json.Range,
        count: u8,
        id: ?json.Range,

        fn clear(self: *Pending) void {
            self.count = 0;
            self.id = null;
        }

        /// False when there is no room: the value is read again.
        fn add(self: *Pending, range: json.Range) bool {
            if (self.count == self.members.len) return false;
            self.members[self.count] = range;
            self.count += 1;
            return true;
        }
    };

    const ItemMember = enum { neutral, type, bag, id, role, phase, content_parts, summary_parts, call_name, call_id, call_arguments, kind_dependent };

    const Block = struct {
        word: ?Word,
        /// Whether the block's `type` appeared more than once.
        types: u2,
        replaying: bool,
        replay: bool,
        start: u64,
        pending: Pending,
        member: enum { neutral, bag, text },
        key_start: u64,
        /// The part record was asked for.
        open: bool,
    };

    pub const Error = error{ OpsOverflow, MisfedWindow, InconsistentSplit };

    pub fn init(self: *Interpreter, operation: codec_abi.Operation) void {
        self.operation = operation;
        self.completed = false;
        self.done_marker = false;
        self.item_count = 0;
        self.added_active = false;
        self.in_event = false;
        self.position = 0;
    }

    pub fn interpret(self: *Interpreter, fed: *const codec_abi.EventFed, ops: *Ops) Error!Status {
        self.ops = ops;
        self.overflowed = false;
        defer self.ops = undefined;
        if (fed.end) {
            if (self.in_event or fed.bytes.len != 0) return error.MisfedWindow;
            if (self.completed) return .done;
            try self.emit(.{ .failed = .provider_connection_closed });
            return .next;
        }
        if (!self.in_event) {
            self.in_event = true;
            self.event_start = fed.offset;
            self.position = fed.offset;
            self.known = null;
            self.startPass();
        }
        if (fed.offset != self.position) return error.MisfedWindow;
        if (fed.event_end) {
            if (fed.bytes.len != 0) return error.MisfedWindow;
            try self.finishEvent();
            return self.answer();
        }
        var consumed: usize = 0;
        while (consumed < fed.bytes.len) {
            var run = fed.bytes[consumed..];
            // The marker is matched byte by byte while the event may be it.
            if (self.done_match <= done_marker_bytes.len) {
                const byte = run[0];
                self.done_match = if (self.done_match < done_marker_bytes.len and done_marker_bytes[self.done_match] == byte) self.done_match + 1 else done_marker_bytes.len + 1;
                run = run[0..1];
            }
            if (self.syntax != null) {
                consumed += run.len;
            } else if (self.reader.feedUntil(run, self)) |count| {
                consumed += count;
            } else |err| {
                self.syntax = err;
                consumed += run.len;
            }
            if (self.seek) |seek| {
                self.flush(fed.offset + consumed);
                self.seek = null;
                switch (seek.level) {
                    .event => unreachable,
                    .item => self.reader.resumeValue(seek.offset, &.{.object}),
                    .block => self.reader.resumeValue(seek.offset, &.{ .object, .object, .array }),
                }
                self.position = self.event_start + seek.offset;
                try self.emit(.{ .need = self.position });
                return self.answer();
            }
            if (self.paused()) break;
        }
        self.position = fed.offset + consumed;
        if (self.syntax == null) self.flush(self.position);
        if (consumed < fed.bytes.len) try self.emit(.{ .need = self.position });
        return self.answer();
    }

    /// Whether the reader stops after the byte just read: a value is to be
    /// read again, or `Ops` has less room than one byte may need.
    pub fn paused(self: *const Interpreter) bool {
        return self.seek != null or Ops.capacity - self.ops.length < reserve;
    }

    fn answer(self: *const Interpreter) Error!Status {
        return if (self.overflowed) error.OpsOverflow else .next;
    }

    fn startPass(self: *Interpreter) void {
        self.reader.init();
        self.done_match = 0;
        self.syntax = null;
        self.seek = null;
        self.raw = .initFill(.{});
        self.string_span = .{};
        const scan = &self.scan;
        scan.type = self.known;
        scan.replay = false;
        scan.path = @splat(.other);
        scan.outer = .initFill(.{});
        scan.nested = .initFill(.{});
        scan.response = .initFill(.{});
        scan.response_error = .initFill(.{});
        scan.details_reason = .{};
        scan.identity = .initFill(.{});
        scan.terminal = .initFill(.{});
        scan.usage = .initFill(.{});
        scan.cached = .{};
        scan.codes = .initFill(.{});
        scan.item_mode = .none;
    }

    fn emit(self: *Interpreter, record: Record) Error!void {
        self.ops.record(record) catch {
            self.overflowed = true;
        };
    }

    /// Callbacks give no error, so a record that does not fit is kept as
    /// `overflowed` and fails the window.
    fn give(self: *Interpreter, record: Record) void {
        self.emit(record) catch unreachable;
    }

    fn at(self: *const Interpreter, offset: u64) u64 {
        return self.event_start + offset;
    }

    // -------------------------------------------------------------- spans

    fn openRaw(self: *Interpreter, span: codec_abi.Span, start: u64) void {
        self.raw.set(span, .{ .open = true, .cursor = start });
    }

    fn closeRaw(self: *Interpreter, span: codec_abi.Span, stop: u64) void {
        self.flushRaw(span, stop);
        self.raw.getPtr(span).open = false;
    }

    fn openString(self: *Interpreter, field: codec_abi.Field, start: u64) void {
        self.string_field = field;
        self.string_span = .{ .open = true, .cursor = start };
    }

    fn closeString(self: *Interpreter, stop: u64) void {
        const span = &self.string_span;
        if (!span.open) return;
        self.give(.{ .string = .{ .field = self.string_field, .last = true, .start = span.cursor, .length = stop - span.cursor } });
        span.open = false;
    }

    /// Give every open span's bytes up to `to`. A span's bytes are given
    /// once, so a value read again gives none twice.
    fn flush(self: *Interpreter, to: u64) void {
        for (std.enums.values(codec_abi.Span)) |span| self.flushRaw(span, to);
        const span = &self.string_span;
        if (span.open and to > span.cursor) {
            self.give(.{ .string = .{ .field = self.string_field, .last = false, .start = span.cursor, .length = to - span.cursor } });
            span.cursor = to;
        }
    }

    fn flushRaw(self: *Interpreter, span: codec_abi.Span, to: u64) void {
        const cursor = self.raw.getPtr(span);
        if (!cursor.open or to <= cursor.cursor) return;
        self.give(.{ .raw = .{ .span = span, .start = cursor.cursor, .length = to - cursor.cursor } });
        cursor.cursor = to;
    }

    /// A bag member already read whole.
    fn giveMember(self: *Interpreter, range: json.Range) void {
        self.give(.{ .raw = .{ .span = .member, .start = range.start, .length = range.length } });
        self.give(.member_end);
    }

    // ----------------------------------------------------------- callbacks

    pub fn key(self: *Interpreter, reader: *const json.Reader, depth: u8) void {
        if (self.seek != null) return;
        if (depth < self.scan.path.len) self.scan.path[depth] = std.meta.stringToEnum(Key, reader.text() orelse "") orelse .other;
        if (depth >= 2 and self.scan.path[1] == .item and self.scan.item_mode == .judged) {
            self.judge.key(reader);
            self.splitKey(reader, depth);
        }
    }

    pub fn begin(self: *Interpreter, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        if (self.seek != null or depth == 0) return;
        const scan = &self.scan;
        if (depth < scan.path.len and reader.arrays.isSet(depth - 1)) scan.path[depth] = .element;
        const path = scan.path;
        if (path[1] == .item and depth >= 2) {
            switch (scan.item_mode) {
                .judged => {
                    self.judge.begin(kind);
                    self.splitBegin(reader, kind, depth);
                },
                .identity => if (depth == 2) if (subset(IdentityKey, path[2])) |name| {
                    scan.identity.getPtr(name).begin(reader);
                    if (name == .id and kind == .string and scan.identity.get(.id).count == 1) self.openString(.added_id, self.at(reader.offset + 1));
                },
                .kind => if (depth == 2 and path[2] == .type) scan.identity.getPtr(.type).begin(reader),
                .none => {},
            }
            return;
        }
        switch (depth) {
            1 => {
                const outer = subset(EventKey, path[1]) orelse return;
                const member = scan.outer.getPtr(outer);
                member.begin(reader);
                if (member.count != 1) return;
                switch (outer) {
                    .item => switch (scan.type orelse {
                        scan.item_mode = .kind;
                        return self.needsType();
                    }) {
                        .done => {
                            scan.item_mode = .judged;
                            self.judge.reset(self.operation);
                            self.judge.begin(kind);
                            self.splitStart(reader, kind);
                        },
                        .added => scan.item_mode = .identity,
                        else => {},
                    },
                    .response => if (scan.type == null) self.needsType(),
                    else => {},
                }
            },
            2 => if (path[1] == .@"error") {
                if (subset(ReportKey, path[2])) |name| scan.nested.getPtr(name).begin(reader);
            } else if (path[1] == .response and scan.outer.get(.response).count == 1) {
                const name = subset(ResponseKey, path[2]) orelse return;
                const member = scan.response.getPtr(name);
                member.begin(reader);
                if (member.count != 1 or scan.type != .completed) return;
                switch (name) {
                    .id => if (kind == .string) self.openString(.response_id, self.at(reader.offset + 1)),
                    .model => if (kind == .string) self.openString(.served_model, self.at(reader.offset + 1)),
                    .usage => self.openRaw(.usage, self.at(reader.offset)),
                    else => {},
                }
            },
            3 => if (path[1] == .response and scan.outer.get(.response).count == 1) switch (path[2]) {
                .@"error" => if (subset(ReportKey, path[3])) |name| scan.response_error.getPtr(name).begin(reader),
                .incomplete_details => if (path[3] == .reason) scan.details_reason.begin(reader),
                .usage => if (subset(UsageKey, path[3])) |name| scan.usage.getPtr(name).begin(reader),
                .output => if (path[3] == .element and self.followsOutput()) {
                    scan.terminal = .initFill(.{});
                    self.openRaw(.terminal, self.at(reader.offset));
                },
                else => {},
            },
            4 => if (path[1] == .response and path[3] == .element and path[2] == .output and self.followsOutput()) {
                if (subset(IdentityKey, path[4])) |name| {
                    scan.terminal.getPtr(name).begin(reader);
                    if (name == .id and kind == .string and scan.terminal.get(.id).count == 1) self.openString(.terminal_id, self.at(reader.offset + 1));
                }
            } else if (path[1] == .response and path[2] == .usage and path[3] == .input_tokens_details and path[4] == .cached_tokens) {
                scan.cached.begin(reader);
            },
            else => {},
        }
    }

    pub fn end(self: *Interpreter, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        if (self.seek != null or depth == 0) return;
        const scan = &self.scan;
        const path = scan.path;
        if (path[1] == .item and depth >= 2) {
            switch (scan.item_mode) {
                .judged => {
                    if (self.splitEnd(reader, kind, depth)) return;
                    self.judge.end(reader, kind);
                },
                .identity => if (depth == 2) if (subset(IdentityKey, path[2])) |name| {
                    scan.identity.getPtr(name).end(reader, kind);
                    if (name == .id and kind == .string and scan.identity.get(.id).count == 1) self.closeString(self.at(reader.offset));
                },
                .kind => if (depth == 2 and path[2] == .type) scan.identity.getPtr(.type).end(reader, kind),
                .none => {},
            }
            return;
        }
        switch (depth) {
            1 => {
                const outer = subset(EventKey, path[1]) orelse return;
                const member = scan.outer.getPtr(outer);
                member.end(reader, kind);
                if (member.count != 1) return;
                switch (outer) {
                    .type => if (kind == .string) {
                        scan.type = eventType(reader);
                    },
                    .code => if (kind == .string) scan.codes.getPtr(.event).keep(reader),
                    .item => if (scan.item_mode == .judged) {
                        if (self.splitEnd(reader, kind, depth)) return;
                        self.judge.end(reader, kind);
                    },
                    else => {},
                }
            },
            2 => if (path[1] == .@"error") {
                const name = subset(ReportKey, path[2]) orelse return;
                scan.nested.getPtr(name).end(reader, kind);
                if (name == .code and kind == .string) scan.codes.getPtr(.nested).keep(reader);
            } else if (path[1] == .response and scan.outer.get(.response).count == 1) {
                const name = subset(ResponseKey, path[2]) orelse return;
                const member = scan.response.getPtr(name);
                member.end(reader, kind);
                if (member.count != 1 or scan.type != .completed) return;
                switch (name) {
                    .id, .model => if (kind == .string) self.closeString(self.at(reader.offset)),
                    .usage => self.closeRaw(.usage, self.at(valueEnd(reader, kind))),
                    else => {},
                }
            },
            3 => if (path[1] == .response and scan.outer.get(.response).count == 1) switch (path[2]) {
                .@"error" => if (subset(ReportKey, path[3])) |name| {
                    scan.response_error.getPtr(name).end(reader, kind);
                    if (name == .code and kind == .string) scan.codes.getPtr(.response).keep(reader);
                },
                .incomplete_details => if (path[3] == .reason) scan.details_reason.end(reader, kind),
                .usage => if (subset(UsageKey, path[3])) |name| scan.usage.getPtr(name).end(reader, kind),
                .output => if (path[3] == .element and self.followsOutput()) {
                    self.closeRaw(.terminal, self.at(valueEnd(reader, kind)));
                    if (terminalKind(kind, &scan.terminal)) |output_kind| {
                        self.give(.{ .terminal = output_kind });
                    } else |err| self.give(.{ .terminal_failed = reasonOf(err) });
                },
                else => {},
            },
            4 => if (path[1] == .response and path[3] == .element and path[2] == .output and self.followsOutput()) {
                if (subset(IdentityKey, path[4])) |name| {
                    scan.terminal.getPtr(name).end(reader, kind);
                    if (name == .id and kind == .string and scan.terminal.get(.id).count == 1) self.closeString(self.at(reader.offset));
                }
            } else if (path[1] == .response and path[2] == .usage and path[3] == .input_tokens_details and path[4] == .cached_tokens) {
                scan.cached.end(reader, kind);
            },
            else => {},
        }
    }

    /// The completed response's first output list is compared with the
    /// streamed items.
    fn followsOutput(self: *const Interpreter) bool {
        return self.scan.type == .completed and self.scan.response.get(.output).count == 1;
    }

    /// A value that needs the event's type began before the type: read the
    /// event again once its end gives the type.
    fn needsType(self: *Interpreter) void {
        self.scan.replay = true;
    }

    fn eventType(reader: *const json.Reader) EventType {
        if (Word.of(reader)) |word| switch (word) {
            .@"response.output_item.added" => return .added,
            .@"response.output_item.done" => return .done,
            .@"response.completed" => return .completed,
            .@"error" => return .error_event,
            .@"response.failed" => return .failed,
            .@"response.incomplete" => return .incomplete,
            else => {},
        };
        const start = reader.text_bytes[0..@intCast(@min(reader.decoded, json.max_text_bytes))];
        return if (std.mem.startsWith(u8, start, "response.output_item.")) .unsupported else .other;
    }

    /// An output list item's identity: its type and nonempty id.
    fn terminalKind(kind: json.Kind, members: *const std.EnumArray(IdentityKey, Named)) Failure!codec_abi.OutputKind {
        if (kind != .object) return error.UnexpectedJsonDelimiter;
        const output_kind = Word.kind(try (try members.getPtrConst(.type).required()).compared()) orelse return error.UnsupportedItemType;
        const id = try members.getPtrConst(.id).required();
        if (id.shape != .string) return error.ExpectedJsonString;
        if (id.decoded == 0) return error.EmptyProviderIdentity;
        return output_kind;
    }

    // --------------------------------------------------------------- split

    fn emitting(split: *const Split) bool {
        return split.live and split.kind != null and !split.replay;
    }

    /// The item value begins.
    fn splitStart(self: *Interpreter, reader: *const json.Reader, kind: json.Kind) void {
        const split = &self.split;
        const start = self.at(reader.offset);
        const replaying = split.replaying and split.start == start;
        split.live = kind == .object;
        if (!replaying) split.kind = null;
        split.replaying = replaying;
        split.replay = false;
        split.start = start;
        split.types = 0;
        split.pending.clear();
        split.member = .neutral;
        split.key_start = start;
        split.phase = .unphased;
        split.array = .none;
        split.elements = 0;
        split.block.replaying = false;
        if (replaying) self.openItem();
    }

    /// The kind is known: the item begins, after the members that waited
    /// for it.
    fn openItem(self: *Interpreter) void {
        const split = &self.split;
        self.give(.{ .item = split.kind.? });
        self.openRaw(.item, split.start);
        for (split.pending.members[0..split.pending.count]) |range| self.giveMember(range);
        if (split.pending.id) |id| self.give(.{ .string = .{ .field = .item_id, .last = true, .start = id.start, .length = id.length } });
        split.pending.clear();
    }

    fn itemMember(kind: ?codec_abi.OutputKind, name: []const u8) ItemMember {
        const Name = enum { type, created_by, id, role, phase, content, summary, name, call_id, arguments };
        const known = std.meta.stringToEnum(Name, name) orelse return .bag;
        switch (known) {
            .type => return .type,
            .created_by => return .neutral,
            .id => return .id,
            else => {},
        }
        return switch (kind orelse return .kind_dependent) {
            .message => switch (known) {
                .role => .role,
                .phase => .phase,
                .content => .content_parts,
                else => .bag,
            },
            .reasoning => switch (known) {
                .summary => .summary_parts,
                .content => .content_parts,
                else => .bag,
            },
            .function_call => switch (known) {
                .name => .call_name,
                .call_id => .call_id,
                .arguments => .call_arguments,
                else => .bag,
            },
            .compaction => .bag,
        };
    }

    fn splitKey(self: *Interpreter, reader: *const json.Reader, depth: u8) void {
        const split = &self.split;
        if (!split.live) return;
        const key_start = self.at(reader.string().start - 1);
        if (depth == 2) {
            split.key_start = key_start;
            split.member = itemMember(split.kind, reader.text() orelse "");
            switch (split.member) {
                .kind_dependent => split.replay = true,
                .bag, .id => if (emitting(split)) self.openRaw(.member, key_start),
                else => {},
            }
        } else if (depth == 4 and split.array != .none) {
            const block = &split.block;
            block.key_start = key_start;
            const name = reader.text() orelse "";
            block.member = if (std.mem.eql(u8, name, "type"))
                .neutral
            else if (block.word) |word|
                if (std.mem.eql(u8, name, textKey(word))) .text else .bag
            else if (std.mem.eql(u8, name, "text") or (split.kind == .message and std.mem.eql(u8, name, "refusal"))) text: {
                // Which member is the text depends on the type.
                block.replay = true;
                break :text .text;
            } else .bag;
            if (block.member == .bag and block.open) self.openRaw(.member, key_start);
        }
    }

    fn splitBegin(self: *Interpreter, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        const split = &self.split;
        if (!split.live) return;
        const text_start = self.at(reader.offset + 1);
        switch (depth) {
            2 => switch (split.member) {
                .id => if (kind == .string and emitting(split)) self.openString(.item_id, text_start),
                .content_parts, .summary_parts => if (kind == .array) {
                    if (emitting(split)) split.array = if (split.member == .content_parts) .content else .summary;
                    split.elements = 0;
                } else {
                    split.member = .bag;
                    if (emitting(split)) self.openRaw(.member, split.key_start);
                },
                .call_name, .call_id, .call_arguments => if (kind == .string and emitting(split)) self.openString(switch (split.member) {
                    .call_name => .call_name,
                    .call_id => .call_id,
                    else => .call_arguments,
                }, text_start),
                else => {},
            },
            3 => if (split.array != .none) {
                split.elements += 1;
                if (kind != .object) {
                    split.live = false;
                    return;
                }
                self.blockStart(reader);
            },
            4 => if (split.array != .none and split.block.member == .text) {
                if (kind != .string) {
                    split.live = false;
                } else if (split.block.open) self.openString(.part_text, text_start);
            },
            else => {},
        }
    }

    /// True when the value is to be read again from its start.
    fn splitEnd(self: *Interpreter, reader: *const json.Reader, kind: json.Kind, depth: u8) bool {
        const split = &self.split;
        if (!split.live) return false;
        const value_end = self.at(valueEnd(reader, kind));
        switch (depth) {
            1 => {
                if (split.kind == null) {
                    split.live = false;
                    return false;
                }
                if (split.replay) {
                    split.replaying = true;
                    self.scan.outer.getPtr(.item).count -= 1;
                    self.seek = .{ .level = .item, .offset = split.start - self.event_start };
                    return true;
                }
                self.closeRaw(.item, value_end);
                split.replaying = false;
            },
            2 => {
                const whole: json.Range = .{ .start = split.key_start, .length = value_end - split.key_start };
                switch (split.member) {
                    .type => {
                        split.types +|= 1;
                        const output_kind = if (kind == .string) Word.kind(Word.of(reader)) else null;
                        if (split.types > 1 or output_kind == null or (split.kind != null and split.kind != output_kind)) {
                            split.live = false;
                        } else if (split.kind == null) {
                            split.kind = output_kind;
                            if (!split.replay) self.openItem();
                        }
                    },
                    .role => if (emitting(split) and !(kind == .string and Word.of(reader) == .assistant)) self.giveMember(whole),
                    .phase => if (emitting(split)) {
                        const word = if (kind == .string) Word.of(reader) else null;
                        if (word == .commentary) {
                            split.phase = .commentary;
                        } else if (word == .final_answer) {
                            split.phase = .final_answer;
                        } else self.giveMember(whole);
                    },
                    .content_parts, .summary_parts => {
                        if (emitting(split) and split.elements == 0) self.giveMember(whole);
                        split.array = .none;
                    },
                    .call_name, .call_id, .call_arguments => if (kind == .string) self.closeString(value_end - 1),
                    .bag, .id => if (emitting(split)) {
                        if (split.member == .id and kind == .string) self.closeString(value_end - 1);
                        self.closeRaw(.member, value_end);
                        self.give(.member_end);
                    } else if (split.kind == null and !split.replay) {
                        if (!split.pending.add(whole)) split.replay = true;
                        if (split.member == .id and kind == .string) split.pending.id = self.contents(reader);
                    },
                    .neutral, .kind_dependent => {},
                }
            },
            3 => if (split.array != .none) return self.blockEnd(),
            4 => if (split.array != .none) {
                const block = &split.block;
                const whole: json.Range = .{ .start = block.key_start, .length = value_end - block.key_start };
                switch (block.member) {
                    .neutral => {
                        block.types +|= 1;
                        const word = if (kind == .string) Word.of(reader) else null;
                        if (block.types > 1 or partKind(split.kind.?, split.array, word) == null) {
                            split.live = false;
                        } else if (block.word == null) {
                            block.word = word;
                            if (!block.replay) self.openPart();
                        }
                    },
                    .text => self.closeString(value_end - 1),
                    .bag => if (block.open) {
                        self.closeRaw(.member, value_end);
                        self.give(.member_end);
                    } else if (!block.replay and !block.pending.add(whole)) {
                        block.replay = true;
                    },
                }
            },
            else => {},
        }
        return false;
    }

    /// The contents of the string value just read, as event offsets.
    fn contents(self: *const Interpreter, reader: *const json.Reader) json.Range {
        const range = reader.string();
        return .{ .start = self.at(range.start), .length = range.length };
    }

    fn blockStart(self: *Interpreter, reader: *const json.Reader) void {
        const block = &self.split.block;
        const start = self.at(reader.offset);
        const replaying = block.replaying and block.start == start;
        if (!replaying) {
            block.word = null;
            // The judge has opened the block's frame.
            self.block_judge_depth = self.judge.depth - 1;
        }
        block.types = 0;
        block.replaying = replaying;
        block.replay = false;
        block.start = start;
        block.pending.clear();
        block.member = .neutral;
        block.key_start = start;
        block.open = false;
        if (replaying) self.openPart();
    }

    fn openPart(self: *Interpreter) void {
        const split = &self.split;
        const block = &split.block;
        self.give(.{ .part = .{ .array = split.array, .kind = partKind(split.kind.?, split.array, block.word).? } });
        block.open = true;
        for (block.pending.members[0..block.pending.count]) |range| self.giveMember(range);
        block.pending.clear();
    }

    fn blockEnd(self: *Interpreter) bool {
        const split = &self.split;
        const block = &split.block;
        if (block.word == null) {
            split.live = false;
            return false;
        }
        if (block.replay) {
            block.replaying = true;
            split.elements -= 1;
            self.judge.depth = self.block_judge_depth;
            self.seek = .{ .level = .block, .offset = block.start - self.event_start };
            return true;
        }
        self.give(.part_end);
        block.replaying = false;
        return false;
    }

    /// The part a block of `array` in an item of `kind` is, by its type.
    fn partKind(kind: codec_abi.OutputKind, array: codec_abi.PartArray, word: ?Word) ?codec_abi.PartKind {
        const known = word orelse return null;
        return switch (array) {
            .summary => if (known == .summary_text) .summary_text else null,
            .content => if (kind == .message) switch (known) {
                .output_text => .output_text,
                .refusal => .refusal,
                else => null,
            } else if (known == .reasoning_text) .reasoning_text else null,
            .none => unreachable,
        };
    }

    fn textKey(word: Word) []const u8 {
        return if (word == .refusal) "refusal" else "text";
    }

    // ------------------------------------------------------------- verdict

    fn finishEvent(self: *Interpreter) Error!void {
        // A first pass reads every byte before it reads the event again.
        if (self.verdict()) |again| {
            if (!again) {
                self.in_event = false;
                return;
            }
            self.known = self.scan.type;
            self.knowKind();
            self.startPass();
            self.position = self.event_start;
            try self.emit(.{ .need = self.event_start });
        } else |err| switch (err) {
            error.OpsOverflow, error.MisfedWindow, error.InconsistentSplit => |fault| return fault,
            else => |failure| {
                self.in_event = false;
                try self.emit(.{ .failed = reasonOf(failure) });
            },
        }
    }

    /// The kind a first pass found for a done event's item, if one string
    /// type named it, so the pass that reads the event again gives the
    /// item's members as they come instead of reading it a third time.
    fn knowKind(self: *Interpreter) void {
        const scan = &self.scan;
        if (scan.type != .done or scan.item_mode != .kind) return;
        const item = scan.outer.get(.item);
        const kind = scan.identity.getPtrConst(.type);
        if (item.count != 1 or kind.count != 1 or kind.shape != .string) return;
        const split = &self.split;
        split.kind = Word.kind(kind.word) orelse return;
        split.start = self.at(item.range.start);
        split.replaying = true;
    }

    /// The event's verdict, in the order acceptance has always checked:
    /// true when it is to be read again knowing its type.
    fn verdict(self: *Interpreter) (Failure || Error)!bool {
        if (self.done_match == done_marker_bytes.len) {
            if (!self.completed or self.done_marker) return error.ContradictoryProviderOutput;
            self.done_marker = true;
            return false;
        }
        if (self.done_marker) return error.LateProviderOutput;
        try self.emit(.{ .at = .{ .stage = .event, .output_index = null } });
        if (self.completed) return error.LateProviderOutput;
        if (self.syntax) |err| return err;
        if (!self.reader.complete()) return self.reader.unfinished();
        const scan = &self.scan;
        if (scan.replay and self.known == null and scan.type != null) return true;
        _ = try (try scan.outer.getPtrConst(.type).required()).compared();
        switch (scan.type.?) {
            .added => try self.added(),
            .done => try self.done(),
            .completed => try self.complete(),
            .error_event => {
                // A top-level code, even null, is the event's own; else a
                // nested error object, if any.
                if (try scan.outer.getPtrConst(.code).get() == null) {
                    if (try scan.outer.getPtrConst(.@"error").get()) |nested| try self.streamError(nested, &scan.nested, scan.codes.getPtrConst(.nested), .typed);
                }
                try self.streamError(null, null, scan.codes.getPtrConst(.event), .untyped);
            },
            .failed => {
                const response = try scan.outer.getPtrConst(.response).required();
                if (response.shape != .object) return error.UnexpectedJsonDelimiter;
                if (try (try scan.response.getPtrConst(.status).required()).compared() != .failed) return error.IncompleteProviderOutput;
                const failure = try scan.response.getPtrConst(.@"error").get() orelse return error.TemporaryProviderFailure;
                try self.streamError(failure, &scan.response_error, scan.codes.getPtrConst(.response), .typed);
            },
            .incomplete => return if (self.incompleteOverflow()) error.ContextOverflow else error.IncompleteProviderOutput,
            .unsupported => return error.UnsupportedEventType,
            .other => {},
        }
        return false;
    }

    fn index(self: *const Interpreter) Failure!u64 {
        const member = try self.scan.outer.getPtrConst(.output_index).required();
        if (member.shape != .number) return error.InvalidProviderIndex;
        return switch (member.digits) {
            .plain => member.integer.?,
            .negative => error.InvalidProviderIndex,
            .overflow => error.Overflow,
            .fractional => error.TrailingJson,
        };
    }

    fn added(self: *Interpreter) (Failure || Error)!void {
        const scan = &self.scan;
        if (self.added_active) return error.ContradictoryProviderOutput;
        const output_index = try self.index();
        try self.emit(.{ .at = .{ .stage = .event, .output_index = output_index } });
        if (output_index != self.item_count) return error.ContradictoryProviderOutput;
        const item = try scan.outer.getPtrConst(.item).required();
        if (item.shape != .object) return error.UnexpectedJsonDelimiter;
        const kind = try terminalKind(.object, &scan.identity);
        try self.emit(.{ .added = kind });
        self.added_active = true;
    }

    fn done(self: *Interpreter) (Failure || Error)!void {
        const output_index = try self.index();
        try self.emit(.{ .at = .{ .stage = .item, .output_index = output_index } });
        if (output_index != self.item_count) return error.ContradictoryProviderOutput;
        _ = try self.scan.outer.getPtrConst(.item).required();
        const omit_reasoning_text = try self.judge.verdict();
        // Every item the grammar accepts was split as it was read.
        if (!self.split.live or self.split.kind != self.judge.item_kind) return error.InconsistentSplit;
        try self.emit(.{ .item_end = .{ .answer_phase = self.judge.answerPhase(), .phase = self.split.phase, .omit_reasoning_text = omit_reasoning_text } });
        self.item_count += 1;
        self.added_active = false;
    }

    fn complete(self: *Interpreter) (Failure || Error)!void {
        const scan = &self.scan;
        try self.emit(.{ .at = .{ .stage = .response, .output_index = null } });
        if (self.added_active) return error.UnfinishedProviderOutputItem;
        try self.emit(.completed);
        const response = try scan.outer.getPtrConst(.response).required();
        if (response.shape != .object) return error.UnexpectedJsonDelimiter;
        const members = &scan.response;
        if (try (try members.getPtrConst(.status).required()).compared() != .completed) return error.UnsupportedResponseStatus;
        const id = try members.getPtrConst(.id).required();
        _ = try id.compared();
        if (id.decoded == 0) return error.EmptyProviderIdentity;
        if (try members.getPtrConst(.model).get()) |model| if (model.shape != .null_value) {
            _ = try model.compared();
            if (model.decoded == 0) return error.EmptyProviderIdentity;
        };
        if ((try members.getPtrConst(.output).required()).shape != .array) return error.UnexpectedJsonDelimiter;
        try self.emit(.terminal_end);
        if (try members.getPtrConst(.usage).get()) |report_value| if (report_value.shape != .null_value) {
            if (report_value.shape != .object) return error.UnexpectedJsonDelimiter;
            try self.emit(.{ .usage = self.usage() });
        };
        try self.emit(.finish);
        self.completed = true;
    }

    /// Rui's four counts from a Responses usage report. `input_tokens`
    /// includes the cached ones, and Responses bills no cache writes. A
    /// count missing, repeated or outside a whole SQLite integer makes the
    /// report unusable.
    fn usage(self: *const Interpreter) ?codec_abi.Usage {
        const members = &self.scan.usage;
        const input = Named.tokens(members.getPtrConst(.input_tokens).get() catch return null) orelse return null;
        const output = Named.tokens(members.getPtrConst(.output_tokens).get() catch return null) orelse return null;
        var cached: u64 = 0;
        if (members.getPtrConst(.input_tokens_details).get() catch return null) |details| if (details.shape != .null_value) {
            if (details.shape != .object) return null;
            if (self.scan.cached.get() catch return null) |count| cached = Named.tokens(count) orelse return null;
        };
        if (cached > input) return null;
        return .{ .uncached = input - cached, .cache_read = cached, .cache_write = 0, .output = output };
    }

    /// A provider error: its report, then context overflow, a refusal or a
    /// failure the Host decides. `failure` is the error object, null for
    /// the event itself; an object's `type` stands in for a missing code,
    /// an event's is only its name.
    fn streamError(self: *Interpreter, failure: ?*const Named, nested: ?*const std.EnumArray(ReportKey, Named), code_text: *const Code, typed: enum { typed, untyped }) (Failure || Error)!noreturn {
        if (failure) |value| {
            if (value.shape == .null_value) return error.TemporaryProviderFailure;
            if (value.shape != .object) return error.UnexpectedJsonDelimiter;
        }
        const scan = &self.scan;
        const fields: Report = if (nested) |members| .{
            .code = members.getPtrConst(.code),
            .type = members.getPtrConst(.type),
            .message = members.getPtrConst(.message),
            .detail = members.getPtrConst(.detail),
        } else .{
            .code = scan.outer.getPtrConst(.code),
            .type = null,
            .message = scan.outer.getPtrConst(.message),
            .detail = scan.outer.getPtrConst(.detail),
        };
        var code_length: u64 = 0;
        if (try fields.code.get()) |code| if (code.shape != .null_value) {
            _ = try code.compared();
            code_length = code.decoded;
            if (code_length != 0) try self.report(.code, code);
        };
        if (code_length == 0 and typed == .typed) {
            if (fields.type.?.get() catch null) |kind| if (kind.shape == .string) try self.report(.code, kind);
        }
        if ((fields.message.get() catch null) orelse (fields.detail.get() catch null)) |message| {
            if (message.shape == .string) try self.report(.message, message);
        }
        const code = code_text.bytes[0..code_text.length];
        if (code_length == code.len and std.mem.eql(u8, code, "context_length_exceeded")) return error.ContextOverflow;
        if (code_length != 0 and code_length == code.len) try self.emit(.{ .refusal = code });
        return error.ReportedProviderFailure;
    }

    const Report = struct { code: *const Named, type: ?*const Named, message: *const Named, detail: *const Named };

    fn report(self: *Interpreter, field: codec_abi.ReportField, member: *const Named) Error!void {
        try self.emit(.{ .report = .{ .field = field, .escape = .json_string_v1, .start = self.at(member.range.start), .length = member.range.length } });
    }

    /// Whether an incomplete response says the request overflowed the
    /// context, by an exact code in its error or its incomplete details.
    /// Any other shape says it did not.
    fn incompleteOverflow(self: *const Interpreter) bool {
        const scan = &self.scan;
        const response = (scan.outer.getPtrConst(.response).required() catch return false);
        if (response.shape != .object) return false;
        const status = scan.response.getPtrConst(.status).required() catch return false;
        if ((status.compared() catch return false) != .incomplete) return false;
        if (scan.response.getPtrConst(.@"error").get() catch return false) |failure| if (failure.shape != .null_value) {
            if (failure.shape != .object) return false;
            if (scan.response_error.getPtrConst(.code).get() catch return false) |code| {
                if ((code.compared() catch return false) == .context_length_exceeded) return true;
            }
        };
        const details = (scan.response.getPtrConst(.incomplete_details).get() catch return false) orelse return false;
        if (details.shape != .object) return false;
        const reason = scan.details_reason.required() catch return false;
        return (reason.compared() catch return false) == .context_length_exceeded;
    }
};

/// Interpret `events`, each one event's data, as the shell feeds them: in
/// windows of at most `most` bytes from where the interpreter reads next,
/// then each event's end, then the stream's. `out` gets one line per
/// record, and `fed` how many bytes the interpreter was fed.
fn interpretForTesting(events: []const []const u8, operation: codec_abi.Operation, most: usize, out: *std.ArrayList(u8), fed: *u64) !void {
    const allocator = std.testing.allocator;
    const interpreter = try allocator.create(Interpreter);
    defer allocator.destroy(interpreter);
    interpreter.init(operation);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(allocator);
    var ops: Ops = .{};
    fed.* = 0;
    for (events) |event| {
        try data.appendSlice(allocator, event);
        var next: u64 = data.items.len - event.len;
        while (true) {
            const event_end = next == data.items.len;
            const bytes = data.items[@intCast(next)..@intCast(@min(data.items.len, next + most))];
            ops.length = 0;
            try std.testing.expectEqual(Status.next, try interpreter.interpret(&.{ .offset = next, .bytes = bytes, .event_end = event_end, .end = false }, &ops));
            fed.* += bytes.len;
            const need = try describeForTesting(&ops, out);
            if (need) |offset| {
                next = offset;
            } else if (event_end) break else next += bytes.len;
        }
    }
    ops.length = 0;
    const status = try interpreter.interpret(&.{ .offset = data.items.len, .bytes = &.{}, .event_end = false, .end = true }, &ops);
    _ = try describeForTesting(&ops, out);
    try out.print(allocator, "{t}\n", .{status});
}

/// One line per record in `ops`; the offset of a `need`, if any.
fn describeForTesting(ops: *const Ops, out: *std.ArrayList(u8)) !?u64 {
    const allocator = std.testing.allocator;
    var need: ?u64 = null;
    var records = ops.records();
    while (try records.next()) |record| {
        switch (record) {
            .raw => |raw| try out.print(allocator, "raw {t} {d}+{d}", .{ raw.span, raw.start, raw.length }),
            .string => |text| try out.print(allocator, "string {t} {d}+{d}{s}", .{ text.field, text.start, text.length, if (text.last) " last" else "" }),
            .item, .added, .terminal => |kind| try out.print(allocator, "{t} {t}", .{ record, kind }),
            .part => |part| try out.print(allocator, "part {t} {t}", .{ part.array, part.kind }),
            .item_end => |item| try out.print(allocator, "item_end {t} {t}{s}", .{ item.answer_phase, item.phase, if (item.omit_reasoning_text) " omit" else "" }),
            .terminal_failed, .failed => |reason| try out.print(allocator, "{t} {t}", .{ record, reason }),
            .usage => |usage| if (usage) |counts| {
                try out.print(allocator, "usage {d} {d} {d} {d}", .{ counts.uncached, counts.cache_read, counts.cache_write, counts.output });
            } else try out.print(allocator, "usage unusable", .{}),
            .at => |at| try out.print(allocator, "at {t} {?d}", .{ at.stage, at.output_index }),
            .need => |offset| {
                need = offset;
                try out.print(allocator, "need {d}", .{offset});
            },
            .refusal => |code| try out.print(allocator, "refusal {s}", .{code}),
            .report => |range| try out.print(allocator, "report {t} {d}+{d}", .{ range.field, range.start, range.length }),
            .member_end, .part_end, .completed, .terminal_end, .finish => try out.print(allocator, "{t}", .{record}),
        }
        try out.append(allocator, '\n');
    }
    return need;
}

/// The lines `events` give with whole windows, and the bytes fed. Smaller
/// windows cut spans into more pieces and need more feeds; every other
/// record is the same.
fn expectInterpreted(events: []const []const u8, operation: codec_abi.Operation, expected: []const u8) !u64 {
    const allocator = std.testing.allocator;
    var fed: u64 = 0;
    var whole: std.ArrayList(u8) = .empty;
    defer whole.deinit(allocator);
    try interpretForTesting(events, operation, 4096, &whole, &fed);
    try std.testing.expectEqualStrings(expected, whole.items);
    for ([_]usize{ 64, 3, 1 }) |most| {
        var cut: std.ArrayList(u8) = .empty;
        defer cut.deinit(allocator);
        var bytes: u64 = undefined;
        try interpretForTesting(events, operation, most, &cut, &bytes);
        var left: std.ArrayList(u8) = .empty;
        defer left.deinit(allocator);
        var right: std.ArrayList(u8) = .empty;
        defer right.deinit(allocator);
        try structureForTesting(whole.items, &left);
        try structureForTesting(cut.items, &right);
        try std.testing.expectEqualStrings(left.items, right.items);
    }
    return fed;
}

/// The lines that name no bytes.
fn structureForTesting(lines: []const u8, out: *std.ArrayList(u8)) !void {
    var iterator = std.mem.splitScalar(u8, lines, '\n');
    while (iterator.next()) |line| {
        if (std.mem.startsWith(u8, line, "raw ") or std.mem.startsWith(u8, line, "string ") or std.mem.startsWith(u8, line, "need ")) continue;
        try out.appendSlice(std.testing.allocator, line);
        try out.append(std.testing.allocator, '\n');
    }
}

const completed_for_testing = "{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}";

test "the interpreter names an item's spans and structure as it reads them" {
    const done = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\",\"annotations\":[]}],\"x\":1}}";
    const fed = try expectInterpreted(&.{ done, completed_for_testing }, .assistant_response,
        \\item message
        \\string item_id 84+1 last
        \\raw member 78+8
        \\member_end
        \\part content output_text
        \\string part_text 147+2 last
        \\raw member 151+16
        \\member_end
        \\part_end
        \\raw member 170+5
        \\member_end
        \\raw item 60+116
        \\need 176
        \\at event null
        \\at item 0
        \\item_end unphased unphased
        \\string response_id 224+1 last
        \\at event null
        \\at response null
        \\completed
        \\terminal_end
        \\finish
        \\done
        \\
    );
    // Its ops nearly full, the interpreter stopped one byte before the
    // event's end, which it is fed again.
    try std.testing.expectEqual(done.len + completed_for_testing.len + 1, fed);
}

/// Interpret one event and expect `line` among its records.
fn expectRecord(event: []const u8, operation: codec_abi.Operation, line: []const u8) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.testing.allocator);
    var fed: u64 = undefined;
    try interpretForTesting(&.{event}, operation, 4096, &out, &fed);
    if (std.mem.indexOf(u8, out.items, line) == null) {
        std.debug.print("expected \"{s}\" in:\n{s}", .{ line, out.items });
        return error.TestExpectedRecord;
    }
}

test "an event that is not JSON fails for the reason validation names" {
    const deep = "{\"a\":" ++ @as([json.max_depth]u8, @splat('[')) ++ "1" ++ @as([json.max_depth]u8, @splat(']')) ++ "}";
    const cases = [_][2][]const u8{
        .{ "{\"type\":", "unexpected_json_end" },
        .{ "{\"a\":1,}", "expected_json_string" },
        .{ "{\"a\" 1}", "unexpected_json_delimiter" },
        .{ "[1]", "unexpected_json_delimiter" },
        .{ "{}x", "trailing_json" },
        .{ "{\"a\":}", "invalid_json_value" },
        .{ "{\"a\":01}", "invalid_json_number" },
        .{ "{\"a\":nul}", "invalid_json_literal" },
        .{ "{\"a\":\"\x01\"}", "invalid_json_string" },
        .{ "{\"a\":\"\\q\"}", "invalid_json_escape" },
        .{ "{\"a\":\"\\udc00\"}", "invalid_json_surrogate" },
        .{ "{\"a\":\"\xff\"}", "invalid_json_utf8" },
        .{ deep, "json_too_deep" },
    };
    var line: [64]u8 = undefined;
    for (cases) |case| try expectRecord(case[0], .assistant_response, try std.fmt.bufPrint(&line, "at event null\nfailed {s}\n", .{case[1]}));
}

test "the judge's verdict on an item reaches the shell as its reason or replay rule" {
    const head = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":";
    const cases = [_][2][]const u8{
        .{ "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"private\"}]}", "item_end unphased unphased omit\n" },
        .{ "{\"type\":\"reasoning\",\"id\":\"r\",\"id\":\"s\",\"encrypted_content\":\"opaque\"}", "failed duplicate_json_field\n" },
        .{ "{\"type\":\"compaction_v2\",\"id\":\"c\",\"encrypted_content\":\"opaque\"}", "failed unsupported_item_type\n" },
        .{ "{\"type\":\"message\",\"id\":\"m\",\"role\":\"user\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", "failed unsupported_message_role\n" },
        .{ "{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", "item_end final_answer final_answer\n" },
    };
    var event: [512]u8 = undefined;
    for (cases) |case| try expectRecord(try std.fmt.bufPrint(&event, "{s}{s}}}", .{ head, case[0] }), .assistant_response, case[1]);
}

test "an event read again because its types came last gives the records it gives in order" {
    const allocator = std.testing.allocator;
    const first = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}],\"id\":\"m\",\"role\":\"assistant\"}}";
    const block = "{\"text\":\"ok\",\"type\":\"output_text\"}";
    const last = "{\"output_index\":0,\"item\":{\"content\":[" ++ block ++ "],\"id\":\"m\",\"role\":\"assistant\",\"type\":\"message\"},\"type\":\"response.output_item.done\"}";
    var structures: [2]std.ArrayList(u8) = @splat(.empty);
    defer for (&structures) |*structure| structure.deinit(allocator);
    var fed: [2]u64 = undefined;
    for ([_][]const u8{ first, last }, &structures, &fed) |event, *structure, *bytes| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try interpretForTesting(&.{ event, completed_for_testing }, .assistant_response, 4096, &out, bytes);
        try structureForTesting(out.items, structure);
    }
    // Only the first pass's coordinates come before them.
    try std.testing.expectEqualStrings("at event null\n", structures[1].items[0 .. structures[1].items.len - structures[0].items.len]);
    try std.testing.expectEqualStrings(structures[0].items, structures[1].items["at event null\n".len..]);
    // The first pass finds the event's and the item's types; the second
    // reads the block again once its type follows its text. The window in
    // which the block ends runs on to the event's end, so those bytes are
    // fed once more after the block.
    const tail = last.len - (std.mem.indexOf(u8, last, block).? + block.len);
    try std.testing.expectEqual(first.len + completed_for_testing.len, fed[0]);
    try std.testing.expectEqual(2 * last.len + block.len + tail + completed_for_testing.len, fed[1]);
}
