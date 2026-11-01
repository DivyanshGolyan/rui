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
/// that appear once count.
pub fn classify(scratch: *ClassifyScratch, body: []const u8, out: *codec_abi.ErrorBody) void {
    out.context_overflow = false;
    out.code = null;
    out.resets_at = null;
    out.report = .{ .code = null, .message = null };
    scratch.init();
    // A body that is not one whole JSON document establishes nothing.
    scratch.reader.read(body, scratch) catch return;
    scratch.find(out);
}

/// The classifier's working state over one body, which `classify` writes
/// before it reads.
pub const ClassifyScratch = struct {
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

    fn init(self: *ClassifyScratch) void {
        self.* = .{
            .outer = null,
            .inner = null,
            .error_object = false,
            .envelope = .initFill(.{}),
            .failure = .initFill(.{}),
            .code_length = 0,
            .resets_at = null,
        };
    }

    fn find(self: *const ClassifyScratch, found: *codec_abi.ErrorBody) void {
        const failure = self.envelope.get(.@"error");
        if (failure.count == 0) {
            found.report.message = report(message(&self.envelope));
            return;
        }
        if (failure.count > 1 or !self.error_object) return;
        const code = self.failure.get(.code);
        if (code.count == 1 and self.code_length != 0) {
            const text = self.code[0..self.code_length];
            if (std.mem.eql(u8, text, "context_length_exceeded")) {
                found.context_overflow = true;
            } else {
                found.code = .of(text);
                if (self.failure.get(.resets_at).count == 1) found.resets_at = self.resets_at;
            }
        }
        // An error object's type stands in for a code that is absent, empty
        // or not a string.
        const named = code.count == 1 and code.is_string and code.range.length != 0;
        const kind = self.failure.get(.type);
        found.report.code = report(if (named) code.range else if (kind.count == 1) kind.string() else null);
        found.report.message = report(message(&self.failure));
    }

    /// `message`, else `detail`; a message that is not a string is left out.
    fn message(members: anytype) ?json.Range {
        const text = members.get(.message);
        if (text.count == 1) return text.string();
        const detail = members.get(.detail);
        return if (detail.count == 1) detail.string() else null;
    }

    fn report(range: ?json.Range) ?codec_abi.ReportRange {
        const value = range orelse return null;
        return .{ .escape = .json_string_v1, .start = value.start, .length = value.length };
    }

    pub fn key(self: *ClassifyScratch, reader: *const json.Reader, depth: u8) void {
        const name = reader.text() orelse "";
        switch (depth) {
            1 => self.outer = std.meta.stringToEnum(Outer, name),
            2 => if (self.inError()) {
                self.inner = std.meta.stringToEnum(Inner, name);
            },
            else => {},
        }
    }

    pub fn begin(self: *ClassifyScratch, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
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

    pub fn end(self: *ClassifyScratch, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
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
    fn inError(self: *const ClassifyScratch) bool {
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

// ------------------------------------------------------------- interpret

const Reason = codec_abi.Reason;
const Range = codec_abi.Range;

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
    for (@typeInfo(Reason).@"enum".field_names) |name| {
        const error_name = codec_abi.reasonName(@field(Reason, name));
        std.debug.assert(@field(Failure, error_name) != error.OutOfMemory);
    }
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
            const slot = @tagName(reading) ++ "_failure";
            return self.failure orelse @field(self, slot);
        }

        fn ambiguousAs(self: Value, comptime reading: Reading) bool {
            const slot = @tagName(reading);
            return self.ambiguous.all or @field(self.ambiguous, slot);
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
                const slot = @tagName(reading);
                const failure_slot = slot ++ "_failure";
                const prior = &@field(frame.aggregate, failure_slot);
                if (prior.* == null) prior.* = if (value.shape != .object) error.UnexpectedJsonDelimiter else value.failureAs(reading);
                if (value.ambiguousAs(reading)) @field(frame.aggregate.ambiguous, slot) = true;
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
const Key = enum { type, output_index, item, response, code, @"error", message, detail, status, id, model, output, usage, incomplete_details, reason, input_tokens, output_tokens, input_tokens_details, cached_tokens, phase, name, call_id, arguments, element, other };

const EventKey = enum { type, output_index, item, response, code, @"error", message, detail };
const ReportKey = enum { code, type, message, detail };
const ResponseKey = enum { status, id, model, output, usage, @"error", incomplete_details };
const UsageKey = enum { input_tokens, output_tokens, input_tokens_details };
/// An item's members its value names outside the grammar's verdict.
const ItemKey = enum { type, id, phase, name, call_id, arguments };

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

    fn contents(self: *const Named) Range {
        return .{ .start = self.range.start, .length = self.range.length };
    }
};

/// A Responses stream's state between events.
pub const Stream = struct {
    operation: codec_abi.Operation,
    completed: bool,
    done_marker: bool,
    item_count: u64,
    added_active: bool,
};

pub fn begin(operation: codec_abi.Operation) Stream {
    return .{ .operation = operation, .completed = false, .done_marker = false, .item_count = 0, .added_active = false };
}

/// The stream ended between events: its verdict, if it fails.
pub fn finish(stream: *const Stream) ?Reason {
    return if (stream.completed) null else .provider_connection_closed;
}

/// One event's reading: the envelope's named values and the item's
/// grammar, which `interpretEvent` writes before it reads.
pub const InterpretScratch = struct {
    reader: json.Reader,
    type: ?EventType,
    path: [6]Key,
    /// The event's first item value is being read.
    in_item: bool,
    outer: std.enums.EnumArray(EventKey, Named),
    nested: std.enums.EnumArray(ReportKey, Named),
    response: std.enums.EnumArray(ResponseKey, Named),
    response_error: std.enums.EnumArray(ReportKey, Named),
    details_reason: Named,
    item: std.enums.EnumArray(ItemKey, Named),
    usage: std.enums.EnumArray(UsageKey, Named),
    cached: Named,
    judge: Judge,
    /// What a provider's error names, kept as `streamError` reaches it.
    failed: codec_abi.Failed,

    fn init(self: *InterpretScratch, operation: codec_abi.Operation) void {
        self.type = null;
        self.path = @splat(.other);
        self.in_item = false;
        self.outer = .initFill(.{});
        self.nested = .initFill(.{});
        self.response = .initFill(.{});
        self.response_error = .initFill(.{});
        self.details_reason = .{};
        self.item = .initFill(.{});
        self.usage = .initFill(.{});
        self.cached = .{};
        self.judge.reset(operation);
        self.failed = .{ .reason = .reported_provider_failure, .refusal = null, .report = .{ .code = null, .message = null } };
    }

    pub fn key(self: *InterpretScratch, reader: *const json.Reader, depth: u8) void {
        if (depth < self.path.len) self.path[depth] = std.meta.stringToEnum(Key, reader.text() orelse "") orelse .other;
        if (depth >= 2 and self.in_item) self.judge.key(reader);
    }

    pub fn begin(self: *InterpretScratch, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        if (depth == 0) return;
        if (depth < self.path.len and reader.arrays.isSet(depth - 1)) self.path[depth] = .element;
        const path = self.path;
        if (path[1] == .item and depth >= 2) {
            if (!self.in_item) return;
            self.judge.begin(kind);
            if (depth == 2) if (subset(ItemKey, path[2])) |name| self.item.getPtr(name).begin(reader);
            return;
        }
        switch (depth) {
            1 => {
                const outer = subset(EventKey, path[1]) orelse return;
                const member = self.outer.getPtr(outer);
                member.begin(reader);
                if (outer == .item and member.count == 1) {
                    self.in_item = true;
                    self.judge.begin(kind);
                }
            },
            2 => if (path[1] == .@"error") {
                if (subset(ReportKey, path[2])) |name| self.nested.getPtr(name).begin(reader);
            } else if (path[1] == .response and self.outer.get(.response).count == 1) {
                if (subset(ResponseKey, path[2])) |name| self.response.getPtr(name).begin(reader);
            },
            3 => if (path[1] == .response and self.outer.get(.response).count == 1) switch (path[2]) {
                .@"error" => if (subset(ReportKey, path[3])) |name| self.response_error.getPtr(name).begin(reader),
                .incomplete_details => if (path[3] == .reason) self.details_reason.begin(reader),
                .usage => if (subset(UsageKey, path[3])) |name| self.usage.getPtr(name).begin(reader),
                else => {},
            },
            4 => if (path[1] == .response and path[2] == .usage and path[3] == .input_tokens_details and path[4] == .cached_tokens) {
                self.cached.begin(reader);
            },
            else => {},
        }
    }

    pub fn end(self: *InterpretScratch, reader: *const json.Reader, kind: json.Kind, depth: u8) void {
        if (depth == 0) return;
        const path = self.path;
        if (path[1] == .item and depth >= 2) {
            if (!self.in_item) return;
            if (depth == 2) if (subset(ItemKey, path[2])) |name| self.item.getPtr(name).end(reader, kind);
            self.judge.end(reader, kind);
            return;
        }
        switch (depth) {
            1 => {
                const outer = subset(EventKey, path[1]) orelse return;
                const member = self.outer.getPtr(outer);
                member.end(reader, kind);
                if (member.count != 1) return;
                switch (outer) {
                    .type => if (kind == .string) {
                        self.type = eventType(reader);
                    },
                    .item => {
                        self.judge.end(reader, kind);
                        self.in_item = false;
                    },
                    else => {},
                }
            },
            2 => if (path[1] == .@"error") {
                if (subset(ReportKey, path[2])) |name| self.nested.getPtr(name).end(reader, kind);
            } else if (path[1] == .response and self.outer.get(.response).count == 1) {
                if (subset(ResponseKey, path[2])) |name| self.response.getPtr(name).end(reader, kind);
            },
            3 => if (path[1] == .response and self.outer.get(.response).count == 1) switch (path[2]) {
                .@"error" => if (subset(ReportKey, path[3])) |name| self.response_error.getPtr(name).end(reader, kind),
                .incomplete_details => if (path[3] == .reason) self.details_reason.end(reader, kind),
                .usage => if (subset(UsageKey, path[3])) |name| self.usage.getPtr(name).end(reader, kind),
                else => {},
            },
            4 => if (path[1] == .response and path[2] == .usage and path[3] == .input_tokens_details and path[4] == .cached_tokens) {
                self.cached.end(reader, kind);
            },
            else => {},
        }
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
};

/// Judge one event's data, `data`, in the order acceptance has always
/// checked: the marker, then lateness, then syntax, then the envelope and
/// the item's grammar.
pub fn interpretEvent(stream: *Stream, scratch: *InterpretScratch, data: []const u8) codec_abi.Event {
    var at: codec_abi.At = .{ .stage = .stream, .output_index = null };
    const what = verdict(stream, scratch, data, &at) catch |err| return .{ .at = at, .what = .{ .failed = failedOf(scratch, err) } };
    return .{ .at = at, .what = what };
}

/// The verdict, with what a provider's error named, if it named any.
fn failedOf(scratch: *const InterpretScratch, err: Failure) codec_abi.Failed {
    var failed = scratch.failed;
    failed.reason = reasonOf(err);
    return failed;
}

const Verdict = @FieldType(codec_abi.Event, "what");

fn verdict(stream: *Stream, scratch: *InterpretScratch, data: []const u8, at: *codec_abi.At) Failure!Verdict {
    scratch.init(stream.operation);
    if (std.mem.eql(u8, data, "[DONE]")) {
        if (!stream.completed or stream.done_marker) return error.ContradictoryProviderOutput;
        stream.done_marker = true;
        return .done_marker;
    }
    if (stream.done_marker) return error.LateProviderOutput;
    at.* = .{ .stage = .event, .output_index = null };
    if (stream.completed) return error.LateProviderOutput;
    try scratch.reader.read(data, scratch);
    _ = try (try scratch.outer.getPtrConst(.type).required()).compared();
    switch (scratch.type.?) {
        .added => return addedItem(stream, scratch, at),
        .done => return doneItem(stream, scratch, at),
        .completed => return completedResponse(stream, scratch, at),
        .error_event => {
            // A top-level code, even null, is the event's own; else a
            // nested error object, if any.
            if (try scratch.outer.getPtrConst(.code).get() == null) {
                if (try scratch.outer.getPtrConst(.@"error").get()) |nested| try streamError(scratch, data, nested, &scratch.nested, .typed);
            }
            try streamError(scratch, data, null, null, .untyped);
        },
        .failed => {
            const response = try scratch.outer.getPtrConst(.response).required();
            if (response.shape != .object) return error.UnexpectedJsonDelimiter;
            if (try (try scratch.response.getPtrConst(.status).required()).compared() != .failed) return error.IncompleteProviderOutput;
            const reported = try scratch.response.getPtrConst(.@"error").get() orelse return error.TemporaryProviderFailure;
            try streamError(scratch, data, reported, &scratch.response_error, .typed);
        },
        .incomplete => return if (incompleteOverflow(scratch)) error.ContextOverflow else error.IncompleteProviderOutput,
        .unsupported => return error.UnsupportedEventType,
        .other => return .other,
    }
}

fn outputIndex(scratch: *const InterpretScratch) Failure!u64 {
    const member = try scratch.outer.getPtrConst(.output_index).required();
    if (member.shape != .number) return error.InvalidProviderIndex;
    return switch (member.digits) {
        .plain => member.integer.?,
        .negative => error.InvalidProviderIndex,
        .overflow => error.Overflow,
        .fractional => error.TrailingJson,
    };
}

fn addedItem(stream: *Stream, scratch: *const InterpretScratch, at: *codec_abi.At) Failure!Verdict {
    if (stream.added_active) return error.ContradictoryProviderOutput;
    const output_index = try outputIndex(scratch);
    at.* = .{ .stage = .event, .output_index = output_index };
    if (output_index != stream.item_count) return error.ContradictoryProviderOutput;
    const item = try scratch.outer.getPtrConst(.item).required();
    if (item.shape != .object) return error.UnexpectedJsonDelimiter;
    const kind = Word.kind(try (try scratch.item.getPtrConst(.type).required()).compared()) orelse return error.UnsupportedItemType;
    const id = try scratch.item.getPtrConst(.id).required();
    if (id.shape != .string) return error.ExpectedJsonString;
    if (id.decoded == 0) return error.EmptyProviderIdentity;
    stream.added_active = true;
    return .{ .added = .{ .kind = kind, .id = id.contents() } };
}

fn doneItem(stream: *Stream, scratch: *const InterpretScratch, at: *codec_abi.At) Failure!Verdict {
    const output_index = try outputIndex(scratch);
    at.* = .{ .stage = .item, .output_index = output_index };
    if (output_index != stream.item_count) return error.ContradictoryProviderOutput;
    const item = try scratch.outer.getPtrConst(.item).required();
    const judge = &scratch.judge;
    const omit_reasoning_text = try judge.verdict();
    const kind = judge.item_kind.?;
    const members = &scratch.item;
    var call: [3]Range = @splat(.{ .start = 0, .length = 0 });
    if (kind == .function_call) for (&call, [_]ItemKey{ .name, .call_id, .arguments }) |*range, name| {
        range.* = members.getPtrConst(name).contents();
    };
    const phase = members.getPtrConst(.phase);
    stream.item_count += 1;
    stream.added_active = false;
    return .{
        .item = .{
            .kind = kind,
            // Rui's form holds only an exact `commentary` or `final_answer`.
            .phase = if (kind != .message or phase.count == 0 or phase.shape != .string) .unphased else if (phase.word == .commentary) .commentary else if (phase.word == .final_answer) .final_answer else .unphased,
            .answer_phase = judge.answerPhase(),
            .omit_reasoning_text = omit_reasoning_text,
            .whole = item.contents(),
            .id = members.getPtrConst(.id).contents(),
            .call = call,
            .members = .{ .offset = item.range.start, .scope = .item, .kind = kind, .array = .none, .part = .opaque_block },
        },
    };
}

fn completedResponse(stream: *Stream, scratch: *const InterpretScratch, at: *codec_abi.At) Failure!Verdict {
    at.* = .{ .stage = .response, .output_index = null };
    if (stream.added_active) return error.UnfinishedProviderOutputItem;
    stream.completed = true;
    var completed: codec_abi.Completed = .{
        .check = null,
        .response_id = .{ .start = 0, .length = 0 },
        .served_model = null,
        .output = .{ .offset = 0, .scope = .output, .kind = .message, .array = .none, .part = .opaque_block },
        .usage = .absent,
    };
    responseCheck(scratch, &completed) catch |err| {
        completed.check = reasonOf(err);
        return .{ .completed = completed };
    };
    completed.usage = usage(scratch) catch |err| .{ .failed = reasonOf(err) };
    return .{ .completed = completed };
}

/// The response's status, id, model and output list, which the Host reads
/// after its completion gate.
fn responseCheck(scratch: *const InterpretScratch, completed: *codec_abi.Completed) Failure!void {
    const response = try scratch.outer.getPtrConst(.response).required();
    if (response.shape != .object) return error.UnexpectedJsonDelimiter;
    const members = &scratch.response;
    if (try (try members.getPtrConst(.status).required()).compared() != .completed) return error.UnsupportedResponseStatus;
    const id = try members.getPtrConst(.id).required();
    _ = try id.compared();
    if (id.decoded == 0) return error.EmptyProviderIdentity;
    completed.response_id = id.contents();
    if (try members.getPtrConst(.model).get()) |model| if (model.shape != .null_value) {
        _ = try model.compared();
        if (model.decoded == 0) return error.EmptyProviderIdentity;
        completed.served_model = model.contents();
    };
    const output = try members.getPtrConst(.output).required();
    if (output.shape != .array) return error.UnexpectedJsonDelimiter;
    completed.output.offset = output.range.start;
}

/// The usage report, after the output list. `input_tokens` includes the
/// cached ones, and Responses bills no cache writes. A count missing,
/// repeated or outside a whole SQLite integer makes the report unusable.
fn usage(scratch: *const InterpretScratch) Failure!@FieldType(codec_abi.Completed, "usage") {
    const report = try scratch.response.getPtrConst(.usage).get() orelse return .absent;
    if (report.shape == .null_value) return .absent;
    if (report.shape != .object) return error.UnexpectedJsonDelimiter;
    return .{ .report = .{ .whole = report.contents(), .counts = usageCounts(scratch) } };
}

fn usageCounts(scratch: *const InterpretScratch) ?codec_abi.Usage {
    const members = &scratch.usage;
    const input = Named.tokens(members.getPtrConst(.input_tokens).get() catch return null) orelse return null;
    const output = Named.tokens(members.getPtrConst(.output_tokens).get() catch return null) orelse return null;
    var cached: u64 = 0;
    if (members.getPtrConst(.input_tokens_details).get() catch return null) |details| if (details.shape != .null_value) {
        if (details.shape != .object) return null;
        if (scratch.cached.get() catch return null) |count| cached = Named.tokens(count) orelse return null;
    };
    if (cached > input) return null;
    return .{ .uncached = input - cached, .cache_read = cached, .cache_write = 0, .output = output };
}

/// A provider error: its report, then context overflow, a refusal or a
/// failure the Host decides. `reported` is the error object, null for the
/// event itself; an object's `type` stands in for a missing code, an
/// event's is only its name.
fn streamError(scratch: *InterpretScratch, data: []const u8, reported: ?*const Named, nested: ?*const std.enums.EnumArray(ReportKey, Named), typed: enum { typed, untyped }) Failure!noreturn {
    if (reported) |value| {
        if (value.shape == .null_value) return error.TemporaryProviderFailure;
        if (value.shape != .object) return error.UnexpectedJsonDelimiter;
    }
    const fields: Report = if (nested) |members| .{
        .code = members.getPtrConst(.code),
        .type = members.getPtrConst(.type),
        .message = members.getPtrConst(.message),
        .detail = members.getPtrConst(.detail),
    } else .{
        .code = scratch.outer.getPtrConst(.code),
        .type = null,
        .message = scratch.outer.getPtrConst(.message),
        .detail = scratch.outer.getPtrConst(.detail),
    };
    const failed = &scratch.failed;
    var code: ?*const Named = null;
    if (try fields.code.get()) |value| if (value.shape != .null_value) {
        _ = try value.compared();
        if (value.decoded != 0) code = value;
    };
    if (code) |value| {
        failed.report.code = reportRange(value);
    } else if (typed == .typed) {
        if (fields.type.?.get() catch null) |kind| if (kind.shape == .string) {
            failed.report.code = reportRange(kind);
        };
    }
    if ((fields.message.get() catch null) orelse (fields.detail.get() catch null)) |message| {
        if (message.shape == .string) failed.report.message = reportRange(message);
    }
    const value = code orelse return error.ReportedProviderFailure;
    if (value.word == .context_length_exceeded) return error.ContextOverflow;
    if (value.decoded <= codec_abi.max_code_bytes) {
        var text: json.Text = undefined;
        json.decode(data[@intCast(value.range.start)..][0..@intCast(value.range.length)], &text);
        failed.refusal = .of(text.slice().?);
    }
    return error.ReportedProviderFailure;
}

const Report = struct { code: *const Named, type: ?*const Named, message: *const Named, detail: *const Named };

fn reportRange(member: *const Named) codec_abi.ReportRange {
    return .{ .escape = .json_string_v1, .start = member.range.start, .length = member.range.length };
}

/// Whether an incomplete response says the request overflowed the context,
/// by an exact code in its error or its incomplete details. Any other shape
/// says it did not.
fn incompleteOverflow(scratch: *const InterpretScratch) bool {
    const response = (scratch.outer.getPtrConst(.response).required() catch return false);
    if (response.shape != .object) return false;
    const status = scratch.response.getPtrConst(.status).required() catch return false;
    if ((status.compared() catch return false) != .incomplete) return false;
    if (scratch.response.getPtrConst(.@"error").get() catch return false) |reported| if (reported.shape != .null_value) {
        if (reported.shape != .object) return false;
        if (scratch.response_error.getPtrConst(.code).get() catch return false) |code| {
            if ((code.compared() catch return false) == .context_length_exceeded) return true;
        }
    };
    const details = (scratch.response.getPtrConst(.incomplete_details).get() catch return false) orelse return false;
    if (details.shape != .object) return false;
    const reason = scratch.details_reason.required() catch return false;
    return (reason.compared() catch return false) == .context_length_exceeded;
}

// ------------------------------------------------------------------ walk
//
// The walk reads an event that `interpretEvent` accepted, so it trusts the
// event's syntax and its item's grammar. It splits an item as acceptance
// has always split one: every part of a recognised array becomes a part,
// whose other block members are its bag, and every member Rui's form does
// not hold goes, as received, into the item bag. A member is Rui's only in
// exactly the expected shape; `created_by` is dropped, as replay drops it.

/// The next step of the walk from `cursor`, which it moves on; null when
/// the walk's item or output list ends.
pub fn nextMember(data: []const u8, cursor: *codec_abi.Cursor) ?codec_abi.Member {
    while (true) switch (cursor.scope) {
        .item => {
            const member = nextKey(data, &cursor.offset) orelse return null;
            switch (itemMember(data, cursor.kind, &member)) {
                .neutral => {},
                .bag => return .{ .bag = member.whole },
                .parts => |array| {
                    cursor.scope = .array;
                    cursor.array = array;
                    cursor.offset = member.value;
                },
            }
        },
        .array => {
            const block = nextElement(data, &cursor.offset) orelse {
                cursor.scope = .item;
                continue;
            };
            const part = partOf(data, block, cursor.kind, cursor.array);
            cursor.scope = .part;
            cursor.part = part.kind;
            cursor.offset = block.start;
            return .{ .part = .{ .array = cursor.array, .kind = part.kind, .text = part.text } };
        },
        .part => {
            const member = nextKey(data, &cursor.offset) orelse {
                cursor.scope = .array;
                return .part_end;
            };
            const name = member.name.slice() orelse "";
            if (std.mem.eql(u8, name, "type") or std.mem.eql(u8, name, textKey(cursor.part))) continue;
            return .{ .bag = member.whole };
        },
        .output => {
            const element = nextElement(data, &cursor.offset) orelse return null;
            return terminalOf(data, element) catch |err| .{ .terminal_failed = reasonOf(err) };
        },
    };
}

/// One object member: its decoded key, its whole `"key":value` bytes and
/// where its value starts.
const ObjectMember = struct { name: json.Text, whole: Range, value: u64 };

/// The member after `offset` (an object's `{` or the end of a member), or
/// null at the object's end; `offset` moves past what is read.
fn nextKey(data: []const u8, offset: *u64) ?ObjectMember {
    var at = json.skipSpace(data, @intCast(offset.*));
    if (data[at] != '}') at = json.skipSpace(data, at + 1);
    if (data[at] == '}') {
        offset.* = at + 1;
        return null;
    }
    const name = json.stringAt(data, at);
    var member: ObjectMember = .{ .name = undefined, .whole = .{ .start = at, .length = 0 }, .value = 0 };
    json.decode(slice(data, name.contents), &member.name);
    const value = json.skipSpace(data, json.skipSpace(data, name.end) + 1);
    const end = json.valueEnd(data, value);
    member.whole.length = end - at;
    member.value = value;
    offset.* = end;
    return member;
}

/// The element after `offset` (an array's `[` or the end of an element), or
/// null at the array's end; `offset` moves past what is read.
fn nextElement(data: []const u8, offset: *u64) ?Range {
    var at = json.skipSpace(data, @intCast(offset.*));
    if (data[at] != ']') at = json.skipSpace(data, at + 1);
    if (data[at] == ']') {
        offset.* = at + 1;
        return null;
    }
    const end = json.valueEnd(data, at);
    offset.* = end;
    return .{ .start = at, .length = end - at };
}

fn slice(data: []const u8, range: json.Range) []const u8 {
    return data[@intCast(range.start)..][0..@intCast(range.length)];
}

/// The value at `start` is a string whose decoded contents are `word`.
fn stringIs(data: []const u8, start: u64, word: Word) bool {
    if (data[@intCast(start)] != '"') return false;
    var text: json.Text = undefined;
    json.decode(slice(data, json.stringAt(data, @intCast(start)).contents), &text);
    return std.mem.eql(u8, text.slice() orelse return false, @tagName(word));
}

fn itemMember(data: []const u8, kind: codec_abi.OutputKind, member: *const ObjectMember) union(enum) { neutral, bag, parts: codec_abi.PartArray } {
    const Name = enum { type, created_by, role, phase, content, summary, name, call_id, arguments };
    const name = std.meta.stringToEnum(Name, member.name.slice() orelse "") orelse return .bag;
    if (name == .type or name == .created_by) return .neutral;
    const array: codec_abi.PartArray = switch (kind) {
        .message => switch (name) {
            .role => return if (stringIs(data, member.value, .assistant)) .neutral else .bag,
            .phase => return if (stringIs(data, member.value, .commentary) or stringIs(data, member.value, .final_answer)) .neutral else .bag,
            .content => .content,
            else => return .bag,
        },
        .reasoning => switch (name) {
            .summary => .summary,
            .content => .content,
            else => return .bag,
        },
        .function_call => return switch (name) {
            .name, .call_id, .arguments => .neutral,
            else => .bag,
        },
        .compaction => return .bag,
    };
    // Only a nonempty array holds parts; any other value stays whole.
    const value: usize = @intCast(member.value);
    if (data[value] != '[' or data[json.skipSpace(data, value + 1)] == ']') return .bag;
    return .{ .parts = array };
}

/// A block of an accepted item: its part kind, by its type, and its text.
fn partOf(data: []const u8, block: Range, kind: codec_abi.OutputKind, array: codec_abi.PartArray) struct { kind: codec_abi.PartKind, text: Range } {
    var type_start: ?u64 = null;
    var text: ?u64 = null;
    var refusal: ?u64 = null;
    var offset = block.start;
    while (nextKey(data, &offset)) |member| {
        const name = member.name.slice() orelse continue;
        if (std.mem.eql(u8, name, "type")) type_start = member.value;
        if (std.mem.eql(u8, name, "text")) text = member.value;
        if (std.mem.eql(u8, name, "refusal")) refusal = member.value;
    }
    var word: json.Text = undefined;
    json.decode(slice(data, json.stringAt(data, @intCast(type_start.?)).contents), &word);
    const part = partKind(kind, array, std.meta.stringToEnum(Word, word.slice().?)).?;
    const start = (if (part == .refusal) refusal else text).?;
    const contents = json.stringAt(data, @intCast(start)).contents;
    return .{ .kind = part, .text = .{ .start = contents.start, .length = contents.length } };
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

fn textKey(kind: codec_abi.PartKind) []const u8 {
    return if (kind == .refusal) "refusal" else "text";
}

/// An output list element's identity: its type and nonempty id.
fn terminalOf(data: []const u8, element: Range) Failure!codec_abi.Member {
    if (data[@intCast(element.start)] != '{') return error.UnexpectedJsonDelimiter;
    const Name = enum { type, id };
    const Found = struct { count: u2 = 0, value: u64 = 0 };
    var found: std.enums.EnumArray(Name, Found) = .initFill(.{});
    var offset = element.start;
    while (nextKey(data, &offset)) |member| {
        const name = std.meta.stringToEnum(Name, member.name.slice() orelse "") orelse continue;
        const field = found.getPtr(name);
        field.count +|= 1;
        field.value = member.value;
    }
    var text: json.Text = undefined;
    _ = try identityString(data, found.get(.type).count, found.get(.type).value, &text);
    if (text.length > max_word_bytes) return error.ProviderValueTooLong;
    const kind = Word.kind(std.meta.stringToEnum(Word, text.slice() orelse "")) orelse return error.UnsupportedItemType;
    const id = try identityString(data, found.get(.id).count, found.get(.id).value, &text);
    if (text.length == 0) return error.EmptyProviderIdentity;
    return .{ .terminal = .{ .kind = kind, .whole = element, .id = id } };
}

/// A member that appears once and is a string, decoded into `text`.
fn identityString(data: []const u8, count: u2, start: u64, text: *json.Text) Failure!Range {
    switch (count) {
        0 => return error.MissingProviderField,
        1 => {},
        else => return error.DuplicateJsonField,
    }
    if (data[@intCast(start)] != '"') return error.ExpectedJsonString;
    const contents = json.stringAt(data, @intCast(start)).contents;
    json.decode(slice(data, contents), text);
    return .{ .start = contents.start, .length = contents.length };
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

test "classify answers the same with 0xAA or leftover scratch" {
    const bodies = [_][]const u8{
        "{\"error\":{\"code\":\"usage_limit_reached\",\"resets_at\":1800000123,\"message\":\"Out.\"}}",
        "{\"error\":{\"code\":\"context_length_exceeded\",\"message\":\"Too long.\"}}",
        "{\"error\":{\"type\":\"invalid_request_error\",\"code\":null,\"detail\":\"d\"}}",
        "{\"detail\":\"Unsupported model\"}",
        "{\"error\":{\"code\":\"cyber_policy\",\"x\":1.2.3}}",
        "{\"error\":{\"code\":\"" ++ @as([80]u8, @splat('c')) ++ "\"}}",
        "",
    };
    const same = struct {
        fn body(expected: *const codec_abi.ErrorBody, actual: *const codec_abi.ErrorBody) !void {
            try std.testing.expectEqual(expected.context_overflow, actual.context_overflow);
            try std.testing.expectEqual(expected.code == null, actual.code == null);
            if (expected.code) |*code| try std.testing.expectEqualStrings(code.slice(), actual.code.?.slice());
            try std.testing.expectEqual(expected.resets_at, actual.resets_at);
            try std.testing.expectEqual(expected.report.code, actual.report.code);
            try std.testing.expectEqual(expected.report.message, actual.report.message);
        }
    };
    var scratch: ClassifyScratch = undefined;
    var fresh: codec_abi.ErrorBody = undefined;
    var again: codec_abi.ErrorBody = undefined;
    for (bodies) |body| {
        @memset(std.mem.asBytes(&scratch), 0xAA);
        @memset(std.mem.asBytes(&fresh), 0xAA);
        classify(&scratch, body, &fresh);
        for (bodies) |other| {
            classify(&scratch, other, &again);
            classify(&scratch, body, &again);
            try same.body(&fresh, &again);
        }
    }
    @memset(std.mem.asBytes(&scratch), 0xAA);
    classify(&scratch, bodies[0], &fresh);
    try std.testing.expectEqualStrings("usage_limit_reached", fresh.code.?.slice());
    try std.testing.expectEqual(@as(?u64, 1_800_000_123), fresh.resets_at);
    try std.testing.expectEqualStrings("Out.", bodies[0][fresh.report.message.?.start..][0..fresh.report.message.?.length]);
}

/// One line per answer to `events` and per step of each walk it gives,
/// then the stream's end.
fn describeForTesting(events: []const []const u8, scratch: *InterpretScratch, out: *std.Io.Writer) !void {
    var stream = begin(.assistant_response);
    for (events) |data| {
        const event = interpretEvent(&stream, scratch, data);
        try out.print("at {t} {?d}\n", .{ event.at.stage, event.at.output_index });
        var walk: ?codec_abi.Cursor = null;
        switch (event.what) {
            .other, .done_marker => try out.print("{t}\n", .{event.what}),
            .added => |added| try out.print("added {t} {d}+{d}\n", .{ added.kind, added.id.start, added.id.length }),
            .item => |item| {
                try out.print("item {t} {t} {t}{s} {d}+{d} id {d}+{d}", .{ item.kind, item.phase, item.answer_phase, if (item.omit_reasoning_text) " omit" else "", item.whole.start, item.whole.length, item.id.start, item.id.length });
                if (item.kind == .function_call) for (item.call) |range| try out.print(" {d}+{d}", .{ range.start, range.length });
                try out.writeByte('\n');
                walk = item.members;
            },
            .completed => |completed| {
                try out.print("completed {?t} id {d}+{d}", .{ completed.check, completed.response_id.start, completed.response_id.length });
                if (completed.served_model) |model| try out.print(" model {d}+{d}", .{ model.start, model.length });
                switch (completed.usage) {
                    .absent => {},
                    .failed => |reason| try out.print(" usage {t}", .{reason}),
                    .report => |report| if (report.counts) |counts| {
                        try out.print(" usage {d}+{d} {d} {d} {d} {d}", .{ report.whole.start, report.whole.length, counts.uncached, counts.cache_read, counts.cache_write, counts.output });
                    } else try out.print(" usage {d}+{d} unusable", .{ report.whole.start, report.whole.length }),
                }
                try out.writeByte('\n');
                if (completed.check == null) walk = completed.output;
            },
            .failed => |failed| {
                try out.print("failed {t}", .{failed.reason});
                if (failed.refusal) |*code| try out.print(" refusal {s}", .{code.slice()});
                inline for (.{ "code", "message" }) |name| if (@field(failed.report, name)) |range| try out.print(" " ++ name ++ " {d}+{d}", .{ range.start, range.length });
                try out.writeByte('\n');
            },
        }
        if (walk) |start| {
            var cursor = start;
            while (nextMember(data, &cursor)) |member| switch (member) {
                .bag => |range| try out.print("  bag {s}\n", .{data[@intCast(range.start)..][0..@intCast(range.length)]}),
                .part => |part| try out.print("  part {t} {t} {s}\n", .{ part.array, part.kind, data[@intCast(part.text.start)..][0..@intCast(part.text.length)] }),
                .part_end => try out.print("  part_end\n", .{}),
                .terminal => |terminal| try out.print("  terminal {t} {d}+{d} id {s}\n", .{ terminal.kind, terminal.whole.start, terminal.whole.length, data[@intCast(terminal.id.start)..][0..@intCast(terminal.id.length)] }),
                .terminal_failed => |reason| try out.print("  terminal_failed {t}\n", .{reason}),
            };
        }
    }
    try out.print("finish {?t}\n", .{finish(&stream)});
}

var testing_scratch: InterpretScratch = undefined;

fn expectDescribed(events: []const []const u8, expected: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);
    try describeForTesting(events, &testing_scratch, &out);
    try std.testing.expectEqualStrings(expected, out.buffered());
}

const completed_for_testing = "{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[]}}";

test "an accepted item walks as its bag members and parts in document order" {
    // The part's text follows a member of its bag, and the event's type
    // follows its item: the walk reads the whole event either way.
    const done = "{\"output_index\":0,\"item\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"final_answer\",\"content\":[{\"annotations\":[],\"type\":\"output_text\",\"te\\u0078t\":\"o\\nk\"},{\"type\":\"refusal\",\"refusal\":\"no\",\"text\":1}],\"x\":{\"y\":[1]},\"created_by\":\"z\"},\"type\":\"response.output_item.done\"}";
    try expectDescribed(&.{ done, completed_for_testing, "[DONE]" },
        \\at item 0
        \\item message final_answer final_answer 25+214 id 32+1
        \\  bag "id":"m"
        \\  part content output_text o\nk
        \\  bag "annotations":[]
        \\  part_end
        \\  part content refusal no
        \\  bag "text":1
        \\  part_end
        \\  bag "x":{"y":[1]}
        \\at response null
        \\completed null id 47+1
        \\at stream null
        \\done_marker
        \\finish null
        \\
    );
}

test "a function call, a reasoning item and the output list walk as acceptance splits them" {
    const call = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"c\",\"status\":\"completed\",\"name\":\"bash\",\"call_id\":\"k\",\"arguments\":\"{}\",\"phase\":\"commentary\"}}";
    const reasoning = "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"reasoning\",\"id\":\"r\",\"summary\":[],\"encrypted_content\":\"e\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"t\"}]}}";
    const completed = "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp\",\"model\":\"gpt\",\"status\":\"completed\",\"output\":[{\"type\":\"function_call\",\"id\":\"c\"},[],{\"id\":\"r\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":2,\"input_tokens_details\":{\"cached_tokens\":4}}}}";
    try expectDescribed(&.{ call, reasoning, completed },
        \\at item 0
        \\item function_call unphased unphased 60+120 id 90+1 122+4 139+1 155+2
        \\  bag "id":"c"
        \\  bag "status":"completed"
        \\  bag "phase":"commentary"
        \\at item 1
        \\item reasoning unphased unphased omit 60+115 id 86+1
        \\  bag "id":"r"
        \\  bag "summary":[]
        \\  bag "encrypted_content":"e"
        \\  part content reasoning_text t
        \\  part_end
        \\at response null
        \\completed null id 47+4 model 62+3 usage 155+80 6 4 0 2
        \\  terminal function_call 98+33 id c
        \\  terminal_failed unexpected_json_delimiter
        \\  terminal_failed missing_provider_field
        \\finish null
        \\
    );
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
    var line: [128]u8 = undefined;
    for (cases) |case| try expectDescribed(&.{case[0]}, try std.fmt.bufPrint(&line, "at event null\nfailed {s}\nfinish provider_connection_closed\n", .{case[1]}));
}

test "the judge's verdict on an item reaches the shell as its reason or replay rule" {
    const head = "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":";
    const cases = [_][2][]const u8{
        .{ "{\"type\":\"reasoning\",\"id\":\"r\",\"encrypted_content\":\"opaque\",\"content\":[{\"type\":\"reasoning_text\",\"text\":\"private\"}]}", "item reasoning unphased unphased omit" },
        .{ "{\"type\":\"reasoning\",\"id\":\"r\",\"id\":\"s\",\"encrypted_content\":\"opaque\"}", "failed duplicate_json_field" },
        .{ "{\"type\":\"compaction_v2\",\"id\":\"c\",\"encrypted_content\":\"opaque\"}", "failed unsupported_item_type" },
        .{ "{\"type\":\"message\",\"id\":\"m\",\"role\":\"user\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", "failed unsupported_message_role" },
        .{ "{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"phase\":\"partial_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"ok\"}]}", "item message unphased commentary" },
    };
    var event: [512]u8 = undefined;
    var buffer: [4096]u8 = undefined;
    for (cases) |case| {
        var out: std.Io.Writer = .fixed(&buffer);
        try describeForTesting(&.{try std.fmt.bufPrint(&event, "{s}{s}}}", .{ head, case[0] })}, &testing_scratch, &out);
        if (std.mem.indexOf(u8, out.buffered(), case[1]) == null) {
            std.debug.print("expected \"{s}\" in:\n{s}", .{ case[1], out.buffered() });
            return error.TestExpectedLine;
        }
    }
}

test "a provider's error names its report, its refusal and context overflow" {
    try expectDescribed(&.{
        "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"m\"}}",
    },
        \\at event null
        \\failed reported_provider_failure code 33+21 message 67+1
        \\finish provider_connection_closed
        \\
    );
    try expectDescribed(&.{"{\"type\":\"response.failed\",\"response\":{\"status\":\"failed\",\"error\":{\"code\":\"cyber_policy\",\"message\":\"no\"}}}"},
        \\at event null
        \\failed reported_provider_failure refusal cyber_policy code 73+12 message 98+2
        \\finish provider_connection_closed
        \\
    );
    try expectDescribed(&.{"{\"type\":\"error\",\"code\":\"context_length_exceeded\",\"message\":\"long\"}"},
        \\at event null
        \\failed context_overflow code 24+23 message 60+4
        \\finish provider_connection_closed
        \\
    );
}

test "every entry point answers the same with 0xAA or leftover scratch" {
    const events = [_][]const u8{
        "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"m\"}}",
        "{\"output_index\":0,\"item\":{\"id\":\"m\",\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"text\":\"ok\",\"type\":\"output_text\",\"annotations\":[]}]},\"type\":\"response.output_item.done\"}",
        "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"c\",\"name\":\"f\",\"call_id\":\"k\",\"arguments\":\"{}\"}}",
        "{\"type\":\"response.output_item.done\",\"output_index\":2,\"item\":{\"type\":\"message\",\"id\":\"m\",\"id\":\"n\"}}",
        "{\"type\":\"error\",\"code\":\"cyber_policy\",\"message\":\"no\"}",
        "{\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"id\":\"m\"}],\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}",
        "{\"a\":[1,}",
        "[DONE]",
    };
    var expected_buffer: [8192]u8 = undefined;
    var expected: std.Io.Writer = .fixed(&expected_buffer);
    @memset(std.mem.asBytes(&testing_scratch), 0xAA);
    try describeForTesting(&events, &testing_scratch, &expected);
    // Each event alone after every other one has left the scratch as it
    // ends, and on scratch of 0xAA.
    for (0..events.len) |first| for (0..events.len) |second| {
        var left_buffer: [2048]u8 = undefined;
        var left: std.Io.Writer = .fixed(&left_buffer);
        @memset(std.mem.asBytes(&testing_scratch), 0xAA);
        try describeForTesting(events[second..][0..1], &testing_scratch, &left);
        var right_buffer: [2048]u8 = undefined;
        var right: std.Io.Writer = .fixed(&right_buffer);
        var discard: std.Io.Writer.Discarding = .init(&.{});
        try describeForTesting(events[first..][0..1], &testing_scratch, &discard.writer);
        try describeForTesting(events[second..][0..1], &testing_scratch, &right);
        try std.testing.expectEqualStrings(left.buffered(), right.buffered());
    };
    // The whole stream, again on leftover scratch.
    var again_buffer: [8192]u8 = undefined;
    var again: std.Io.Writer = .fixed(&again_buffer);
    try describeForTesting(&events, &testing_scratch, &again);
    try std.testing.expectEqualStrings(expected.buffered(), again.buffered());
    try std.testing.expect(std.mem.indexOf(u8, expected.buffered(), "  part content output_text ok\n  bag \"annotations\":[]\n  part_end\n") != null);
}
