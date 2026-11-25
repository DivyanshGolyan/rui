const std = @import("std");
const codec_abi = @import("../codec_abi.zig");
const json = @import("json.zig");

pub const dialect: codec_abi.Dialect = .openai_responses;

pub const manifest: codec_abi.Manifest = .{
    .observe = .{
        .request_id = "x-request-id",
        .model = "openai-model",
        .alternate_model = "x-openai-model",
        .turn_state = "x-codex-turn-state",
        .primary_used = "x-codex-primary-used-percent",
        .primary_minutes = "x-codex-primary-window-minutes",
        .primary_reset_at = "x-codex-primary-reset-at",
        .secondary_used = "x-codex-secondary-used-percent",
        .secondary_minutes = "x-codex-secondary-window-minutes",
        .secondary_reset_at = "x-codex-secondary-reset-at",
    },
};

const ItemHeader = codec_abi.ItemHeader;
const Pieces = codec_abi.Pieces;

pub const Version = enum {
    one,
    two,
    three,

    pub fn declaresTools(self: Version) bool {
        return self != .one;
    }

    pub fn carriesEffort(self: Version) bool {
        return self == .two;
    }
};

/// How version three asks for compaction, at the end of a compaction
/// request. The provider refuses a threshold under 1000 tokens, and a
/// compaction Operation runs only on a large context, so 1000 always
/// compacts. No tool choice keeps the reply the provider writes while it
/// compacts from calling a function or searching the web.
const compaction_request = ",\"tool_choice\":\"none\",\"context_management\":[{\"type\":\"compaction\",\"compact_threshold\":1000}]";

pub const Carry = struct {
    input: enum { unopened, first, comma, owed } = .unopened,
    version: Version,
    effort: ?codec_abi.Effort = null,
};

pub fn initial(version: Version, starting_effort: ?codec_abi.Effort) Carry {
    return switch (version) {
        .one, .three => .{ .version = version },
        .two => .{ .version = .two, .effort = starting_effort },
    };
}

pub const Encoder = struct {
    carry: Carry,
    omit_reasoning_text: bool = false,
    array: codec_abi.PartArray = .none,
    tool_comma: bool = false,
    compact: bool = false,

    input_part_comma: bool = false,

    pub fn encodeItem(self: *Encoder, header: *const ItemHeader, out: *Pieces) error{Declined}!void {
        out.len = 0;
        switch (header.item) {
            .settings => |*settings| {
                out.literal("{\"model\":\"");
                out.content(0, .json_string_v1);
                out.literal(envelope);
                const top = switch (self.carry.version) {
                    .one, .three => settings.effort,
                    .two => settings.starting_effort,
                };
                if (top) |effort| out.literal(switch (effort) {
                    inline else => |value| ",\"reasoning\":{\"effort\":\"" ++ @tagName(value) ++ "\"}",
                });
            },
            .message => |author| {
                if (author == .instruction and self.carry.version == .one and self.carry.input == .unopened) {
                    out.literal(",\"instructions\":\"");
                    out.content(0, .json_string_v1);
                    out.literal("\",\"input\":[");
                    self.carry.input = .first;
                    return;
                }
                self.separateInput(out);
                out.literal(switch (author) {
                    .user => "{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"",
                    .instruction => "{\"role\":\"developer\",\"content\":[{\"type\":\"input_text\",\"text\":\"",
                });
                if (header.has(1)) {
                    out.content(1, .json_string_v1);
                    out.literal("\"},{\"type\":\"input_text\",\"text\":\"");
                }
                out.content(0, .json_string_v1);
                out.literal("\"}]}");
            },
            .output_open => |output| {
                self.separateInput(out);
                self.omit_reasoning_text = output.omit_reasoning_text;
                self.array = .none;
                switch (output.kind) {
                    .reasoning => out.literal("{\"type\":\"reasoning\""),
                    .compaction => out.literal("{\"type\":\"compaction\""),
                    .web_search_call => out.literal("{\"type\":\"web_search_call\""),
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
            .image_message_open => |author| {
                self.separateInput(out);
                self.input_part_comma = false;
                out.literal(switch (author) {
                    .user => "{\"role\":\"user\",\"content\":[",
                    .instruction => "{\"role\":\"developer\",\"content\":[",
                });
            },
            .image_tool_open => {
                self.separateInput(out);
                self.input_part_comma = false;
                out.literal("{\"type\":\"function_call_output\",\"call_id\":\"");
                out.content(0, .json_string_v1);
                out.literal("\",\"output\":[");
            },
            .input_text => {
                if (self.input_part_comma) out.literal(",");
                self.input_part_comma = true;
                out.literal("{\"type\":\"input_text\",\"text\":\"");
                out.content(0, .json_string_v1);
                out.literal("\"}");
            },
            .input_image => |mime| {
                if (self.input_part_comma) out.literal(",");
                self.input_part_comma = true;
                out.literal(switch (mime) {
                    .png => "{\"type\":\"input_image\",\"image_url\":\"data:image/png;base64,",
                    .jpeg => "{\"type\":\"input_image\",\"image_url\":\"data:image/jpeg;base64,",
                });
                out.base64(0);
                out.literal("\",\"detail\":\"auto\"}");
            },
            .image_message_close, .image_tool_close => out.literal("]}"),
            .operation => |effort| if (self.carry.version.carriesEffort() and !std.meta.eql(effort, self.carry.effort)) {
                self.changeEffort(effort orelse return error.Declined, out);
            },
            .effort_update => |effort| if (self.carry.version.carriesEffort()) self.changeEffort(effort, out),
            .declare_open => {
                if (!self.carry.version.declaresTools()) return error.Declined;
                self.separateInput(out);
                self.tool_comma = false;
                out.literal("{\"type\":\"additional_tools\",\"role\":\"developer\",\"tools\":[");
            },
            .declared_tool => {
                if (!self.carry.version.declaresTools()) return error.Declined;
                self.functionTool(out);
            },
            .declare_close => {
                if (!self.carry.version.declaresTools()) return error.Declined;
                self.tool_comma = false;
                out.literal("]}");
            },
            .history_start => switch (self.carry.input) {
                .unopened => {
                    out.literal(",\"input\":[");
                    self.carry.input = .first;
                },
                .comma => {
                    out.literal(",");
                    self.carry.input = .owed;
                },
                .first, .owed => {},
            },
            .history_end => {},
            .compaction_trigger => switch (self.carry.version) {
                .one, .two => {
                    self.separateInput(out);
                    out.literal("{\"type\":\"compaction_trigger\"}");
                },
                .three => self.compact = true,
            },
            .tools_start => {
                switch (self.carry.input) {
                    .unopened => {
                        out.literal(",\"input\":[");
                        self.carry.input = .first;
                    },
                    .owed => return error.Declined,
                    .first, .comma => {},
                }
                self.tool_comma = false;
                out.literal("],\"tools\":[");
            },
            .tool => {
                if (self.carry.version.declaresTools()) return error.Declined;
                self.functionTool(out);
            },
            .web_search => {
                if (self.tool_comma) out.literal(",");
                self.tool_comma = true;
                out.literal("{\"type\":\"web_search\",\"external_web_access\":true}");
            },
            .text_format => if (header.has(0)) {
                out.literal("],\"text\":{\"verbosity\":\"low\",\"format\":{\"type\":\"json_schema\",\"name\":\"rui_output\",\"strict\":true,\"schema\":");
                out.content(0, .verbatim);
                out.literal("}}");
            } else out.literal("],\"text\":{\"verbosity\":\"low\"}"),
            .request_end => out.literal(if (self.compact) compaction_request ++ "}" else "}"),
        }
    }

    fn functionTool(self: *Encoder, out: *Pieces) void {
        if (self.tool_comma) out.literal(",");
        self.tool_comma = true;
        out.literal("{\"type\":\"function\",\"name\":\"");
        out.content(0, .json_string_v1);
        out.literal("\",\"description\":\"");
        out.content(1, .json_string_v1);
        // Explicit: an omitted `strict` lets the provider make the schema
        // strict, requiring every field; Rui checks calls.
        out.literal("\",\"strict\":false,\"parameters\":");
        out.content(2, .verbatim);
        out.literal("}");
    }

    fn changeEffort(self: *Encoder, effort: codec_abi.Effort, out: *Pieces) void {
        self.separateInput(out);
        out.literal(switch (effort) {
            inline else => |value| "{\"type\":\"configuration_update\",\"reasoning\":{\"effort\":\"" ++ @tagName(value) ++ "\"}}",
        });
        self.carry.effort = effort;
    }

    fn separateInput(self: *Encoder, out: *Pieces) void {
        switch (self.carry.input) {
            .unopened => out.literal(",\"input\":["),
            .comma => out.literal(","),
            .first, .owed => {},
        }
        self.carry.input = .comma;
    }
};

pub const RequestHeader = enum(u8) { accept, @"session-id", originator };

pub fn requestHeaders(settings: *const codec_abi.Settings, out: *codec_abi.Headers) void {
    out.count = 0;
    out.add(RequestHeader.accept, "text/event-stream");
    out.add(RequestHeader.@"session-id", &std.fmt.bytesToHex(settings.session_affinity, .lower));
    out.add(RequestHeader.originator, "rui");
}

const RefusalCode = enum {
    insufficient_quota,
    credit_balance_exhausted,
    organization_spend_limit_exceeded,
    project_spend_limit_exceeded,
    usage_limit_reached,
    subscription_sharing_usage_limit_exceeded,
    subscription_sharing_usage_unavailable,
    usage_not_included,
    cyber_policy,
    bio_policy,
    misalignment_policy_violation,
    invalid_prompt,
    model_not_found,
};

fn refusalOf(code: []const u8) ?codec_abi.Refusal {
    return switch (std.meta.stringToEnum(RefusalCode, code) orelse return null) {
        .insufficient_quota, .credit_balance_exhausted, .organization_spend_limit_exceeded, .project_spend_limit_exceeded, .usage_limit_reached, .subscription_sharing_usage_limit_exceeded, .subscription_sharing_usage_unavailable => .quota,
        .usage_not_included => .plan,
        .cyber_policy, .bio_policy, .misalignment_policy_violation, .invalid_prompt => .policy,
        .model_not_found => .model_unavailable,
    };
}

comptime {
    for (std.meta.fieldNames(RefusalCode)) |name| std.debug.assert(name.len <= json.max_text_bytes);
}

/// What one member of an error object says: `.absent` (missing, null, not a string, or
/// repeated where a repeat voids it), `.unreadable` (a string with no readable text), or the text.
const Authority = union(enum) { absent, unreadable, text: []const u8 };

/// The refusal word an error object names. A string `code` is the authority whenever it is
/// present, even an unreadable one, which names nothing and never falls back to `type`.
/// Without a string `code`, the `type` string is the authority.
fn refusalWord(code: Authority, kind: Authority) ?[]const u8 {
    const named = switch (code) {
        .absent => kind,
        .unreadable, .text => code,
    };
    return switch (named) {
        .text => |text| text,
        .absent, .unreadable => null,
    };
}

pub fn classify(scratch: *ClassifyScratch, body: []const u8, out: *codec_abi.ErrorBody) void {
    out.context_overflow = false;
    out.refusal = null;
    out.resets_at = null;
    out.report = .{ .code = null, .message = null };
    scratch.init();
    scratch.reader.read(body, scratch) catch {
        scratch.error_object = false;
        return;
    };
    scratch.find(out);
}

pub fn effortChangeRefused(scratch: *const ClassifyScratch, status: u16, body: []const u8) bool {
    if (status != 400 and status != 422) return false;
    if (scratch.envelope.get(.@"error").count != 1 or !scratch.error_object) return false;
    if (scratch.failure.get(.param).count != 1 or scratch.failure.get(.code).count > 1 or scratch.failure.get(.type).count > 1) return false;
    const code = scratch.code[0..scratch.code_length];
    const invalid = for ([_][]const u8{ "unsupported_value", "unsupported_parameter", "invalid_value", "invalid_parameter", "invalid_request_error", "unknown_parameter", "unsupported_item_type" }) |known| {
        if (std.mem.eql(u8, code, known)) break true;
    } else scratch.code_length == 0 and scratch.invalid_request_type;
    if (!invalid) return false;
    if (scratch.effort_parameter) return true;
    if (!scratch.item_parameter) return false;
    const message = ClassifyScratch.message(&scratch.failure) orelse return false;
    const text = body[@intCast(message.start)..][0..@intCast(message.length)];
    for ([_][]const u8{
        "configuration_update is not supported",
        "'configuration_update' is not supported",
        "Invalid value: 'configuration_update'",
        "Unsupported value: 'configuration_update'",
        "Unsupported item type: 'configuration_update'",
        "Unsupported input type: 'configuration_update'",
    }) |prefix| if (std.mem.startsWith(u8, text, prefix)) return true;
    return false;
}

pub const ClassifyScratch = struct {
    reader: json.Reader = undefined,
    outer: ?Outer,
    inner: ?Inner,
    error_object: bool,
    envelope: std.enums.EnumArray(Outer, Member),
    failure: std.enums.EnumArray(Inner, Member),
    code: [json.max_text_bytes]u8 = undefined,
    code_length: u8,
    kind: [json.max_text_bytes]u8 = undefined,
    kind_length: u8,
    resets_at: ?u64,
    effort_parameter: bool,
    item_parameter: bool,
    invalid_request_type: bool,

    const Outer = enum { @"error", message, detail };
    const Inner = enum { code, type, message, detail, resets_at, param };

    const Member = struct {
        count: u2 = 0,
        is_string: bool = false,
        range: Range = .{ .start = 0, .length = 0 },

        fn string(self: Member) ?Range {
            return if (self.is_string) self.range else null;
        }

        fn set(self: *Member, range: Range) void {
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
            .kind_length = 0,
            .resets_at = null,
            .effort_parameter = false,
            .item_parameter = false,
            .invalid_request_type = false,
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
        const kind = self.failure.get(.type);
        const code_authority: Authority = switch (code.count) {
            0 => .absent,
            1 => if (code.is_string) .{ .text = self.code[0..self.code_length] } else .absent,
            else => .unreadable,
        };
        const kind_authority: Authority = if (kind.count == 1 and kind.is_string) .{ .text = self.kind[0..self.kind_length] } else .absent;
        if (refusalWord(code_authority, kind_authority)) |text| {
            if (std.mem.eql(u8, text, "context_length_exceeded")) {
                found.context_overflow = true;
            } else if (refusalOf(text)) |refusal| {
                found.refusal = refusal;
                if (self.failure.get(.resets_at).count == 1) found.resets_at = self.resets_at;
            }
        }
        const named = code.count == 1 and code.is_string and code.range.length != 0;
        found.report.code = report(if (named) code.range else if (kind.count == 1) kind.string() else null);
        found.report.message = report(message(&self.failure));
    }

    fn message(members: anytype) ?Range {
        const text = members.get(.message);
        if (text.count == 1) return text.string();
        const detail = members.get(.detail);
        return if (detail.count == 1) detail.string() else null;
    }

    fn report(range: ?Range) ?codec_abi.ReportRange {
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
                if (inner == .type) self.kind_length = 0;
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
                    if (inner == .type) self.invalid_request_type = if (reader.text()) |text| std.mem.eql(u8, text, "invalid_request_error") else false;
                    if (inner == .param) if (reader.text()) |text| {
                        self.effort_parameter = std.mem.eql(u8, text, "reasoning.effort");
                        if (std.mem.startsWith(u8, text, "input[")) if (std.mem.indexOfScalar(u8, text, ']')) |end_index| {
                            const digits = text[6..end_index];
                            const numbered = digits.len != 0 and for (digits) |byte| {
                                if (byte < '0' or byte > '9') break false;
                            } else true;
                            if (numbered) {
                                self.effort_parameter = std.mem.eql(u8, text[end_index + 1 ..], ".reasoning.effort");
                                self.item_parameter = std.mem.eql(u8, text[end_index + 1 ..], ".type");
                            }
                        };
                    };
                    if (inner == .code) if (reader.text()) |text| {
                        @memcpy(self.code[0..text.len], text);
                        self.code_length = @intCast(text.len);
                    };
                    if (inner == .type) if (reader.text()) |text| {
                        @memcpy(self.kind[0..text.len], text);
                        self.kind_length = @intCast(text.len);
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

    fn inError(self: *const ClassifyScratch) bool {
        return self.outer == .@"error" and self.error_object;
    }

    fn start(member: *Member) void {
        member.count +|= 1;
        member.is_string = false;
    }
};

const envelope = "\",\"parallel_tool_calls\":true,\"store\":false,\"stream\":true,\"include\":[\"reasoning.encrypted_content\"]";

const Reason = codec_abi.Reason;
const Range = codec_abi.Range;

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
    web_search_call,
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
            .web_search_call => .web_search_call,
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

fn valueEnd(reader: *const json.Reader, kind: json.Kind) u64 {
    return if (kind == .number) reader.offset else reader.offset + 1;
}

const max_word_bytes = 256;

const Judge = struct {
    operation: codec_abi.Operation,
    frames: [max_frames]Frame,
    values: [values_count]Value,
    depth: u8,
    ignored: u8,
    result: Value,
    item_kind: ?codec_abi.OutputKind,

    const max_frames = 5;

    const Name = enum { type, text, refusal, annotations, cell_id, executed_tool_calls, tool_calls_complete, id, status, role, phase, internal_chat_message_metadata_passthrough, content, encrypted_content, summary, name, call_id, arguments, caller, async, namespace, encrypted_function_args };
    const name_count = @typeInfo(Name).@"enum".field_names.len;
    const Names = std.bit_set.IntegerBitSet(name_count);

    const capacities = [max_frames]usize{
        name_count,
        reach(&.{ type_fields, metadata_fields }),
        reach(&.{ type_fields, refusal_fields, output_text_fields, text_fields }),
        0,
        reach(&.{type_fields}),
    };
    const starts = blk: {
        var start: [max_frames + 1]usize = undefined;
        start[0] = 0;
        for (capacities, 0..) |capacity, depth| start[depth + 1] = start[depth] + capacity;
        break :blk start;
    };
    const values_count = starts[max_frames];

    fn reach(comptime tables: []const Consumed) usize {
        var count: usize = 0;
        for (tables) |table| {
            for (table.plain) |name| count = @max(count, @as(usize, @backingInt(name)) + 1);
            for (table.nested) |field| count = @max(count, @as(usize, @backingInt(field[0])) + 1);
        }
        return count;
    }

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
        failure: ?Incompatibility = null,
        output_failure: ?Incompatibility = null,
        reasoning_failure: ?Incompatibility = null,
        summary_failure: ?Incompatibility = null,
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
        present: Names,
        fields: []Value,
        aggregate: Value,

        fn lookup(self: *const Frame, name: Name) Value {
            return if (self.present.isSet(@backingInt(name))) self.fields[@backingInt(name)] else .{};
        }

        fn get(self: *const Frame, comptime name: Name) Incompatibility!Value {
            const value = self.lookup(name);
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

        fn blocks(self: *const Frame, comptime name: Name, comptime reading: Reading) Incompatibility!void {
            const value = try self.get(name);
            if (value.shape == .absent) return;
            if (value.shape != .array) return error.UnexpectedJsonDelimiter;
            if (value.failureAs(reading)) |err| return err;
        }

        fn consumesDuplicate(self: *const Frame, comptime field_names: []const Name, comptime reading: ?Reading) bool {
            inline for (field_names) |name| {
                const value = self.lookup(name);
                if (value.duplicate) return true;
                if (if (reading) |consumed| value.ambiguousAs(consumed) else value.ambiguous.all) return true;
            }
            return false;
        }
    };

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
            .web_search_call => .{ .plain = &.{.encrypted_content} },
            .function_call => .{ .plain = &.{ .name, .call_id, .arguments, .caller, .async, .namespace, .encrypted_function_args } },
            .message => .{ .plain = &.{ .role, .phase }, .nested = &.{.{ .content, .output }} },
        });
    }
    const type_fields: Consumed = .{ .plain = &.{.type} };
    const refusal_fields: Consumed = .{ .plain = &.{.refusal} };
    const output_text_fields: Consumed = .{ .plain = &.{.text}, .nested = &.{.{ .annotations, .output }} };
    const text_fields: Consumed = .{ .plain = &.{.text} };
    const metadata_fields: Consumed = .{ .plain = &.{ .cell_id, .executed_tool_calls, .tool_calls_complete } };

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

    fn reset(self: *Judge, operation: codec_abi.Operation) void {
        self.operation = operation;
        self.depth = 0;
        self.ignored = 0;
        self.result = .{};
        self.item_kind = null;
    }

    fn key(self: *Judge, reader: *const json.Reader) void {
        if (self.ignored != 0) return;
        const frame = &self.frames[self.depth - 1];
        const name = std.meta.stringToEnum(Name, reader.text() orelse "") orelse {
            frame.key = null;
            return;
        };
        frame.key = if (@backingInt(name) < frame.fields.len) name else null;
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
        self.frames[self.depth] = .{
            .kind = child,
            .object = object,
            .key = null,
            .present = .empty,
            .fields = self.values[starts[self.depth]..starts[self.depth + 1]],
            .aggregate = .{ .shape = .array },
        };
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

    fn verdict(self: *const Judge) Incompatibility!bool {
        if (self.result.shape != .object) return error.UnexpectedJsonDelimiter;
        if (self.result.failure) |err| return err;
        std.debug.assert(!self.result.ambiguous.all);
        return self.replaysReasoningText();
    }

    fn replaysReasoningText(self: *const Judge) bool {
        if (self.item_kind != .reasoning) return false;
        const content = self.frames[0].get(.content) catch unreachable;
        return content.shape == .array and content.length != 0;
    }

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
                const index = @backingInt(name);
                const duplicate = frame.present.isSet(index);
                frame.present.set(index);
                frame.fields[index] = value;
                frame.fields[index].duplicate = duplicate;
            }
            frame.key = null;
        } else {
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

    fn ambiguity(frame: *const Frame) Readings {
        const declared = frame.lookup(.type);
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
                    .web_search_call => {
                        const rules = Rules(kindFields(.web_search_call)){ .frame = frame };
                        if (self.operation == .compaction) return error.UnsupportedProviderOutput;
                        const status = try rules.get(.status);
                        if (status.shape != .absent and !(try rules.word(.status)).is(.completed) and !status.is(.failed)) return error.UnsupportedItemStatus;
                        const encrypted = try rules.get(.encrypted_content);
                        switch (encrypted.shape) {
                            .absent, .null_value, .string => {},
                            else => return error.ExpectedJsonString,
                        }
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

    fn textBlock(frame: *const Frame, kind: Value, comptime expected: Word) Incompatibility!void {
        if (!kind.is(expected)) return error.UnsupportedReasoningBlock;
        _ = try (Rules(text_fields){ .frame = frame }).string(.text);
    }
};

const EventType = enum { added, done, completed, error_event, failed, incomplete, unsupported, other };

const Key = enum { type, output_index, item, response, code, @"error", message, detail, status, id, model, output, usage, incomplete_details, reason, input_tokens, output_tokens, input_tokens_details, cached_tokens, phase, name, call_id, arguments, element, other };

const EventKey = enum { type, output_index, item, response, code, @"error", message, detail };
const ReportKey = enum { code, type, message, detail };
const ResponseKey = enum { status, id, model, output, usage, @"error", incomplete_details };
const UsageKey = enum { input_tokens, output_tokens, input_tokens_details };
const ItemKey = enum { type, id, phase, name, call_id, arguments };

fn subset(comptime T: type, key: Key) ?T {
    return std.meta.stringToEnum(T, @tagName(key));
}

const Named = struct {
    count: u2 = 0,
    shape: Shape = .absent,
    word: ?Word = null,
    decoded: u64 = 0,
    range: Range = .{ .start = 0, .length = 0 },
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

    fn compared(self: *const Named) Failure!?Word {
        if (self.shape != .string) return error.ExpectedJsonString;
        if (self.decoded > max_word_bytes) return error.ProviderValueTooLong;
        return self.word;
    }

    fn tokens(self: ?*const Named) ?u64 {
        const member = self orelse return null;
        if (member.shape != .number or member.digits != .plain) return null;
        return if (member.integer.? > std.math.maxInt(i64)) null else member.integer.?;
    }

    fn walked(self: *Named, data: []const u8, start: usize, value: json.Value) void {
        self.count +|= 1;
        self.shape = switch (data[start]) {
            '"' => .string,
            '{' => .object,
            '[' => .array,
            't' => .true_value,
            'f' => .false_value,
            'n' => .null_value,
            else => .number,
        };
        const contents = value.string orelse return;
        var text: json.Text = .{ .length = 0 };
        json.decode(slice(data, contents), &text);
        self.range = contents;
        self.decoded = text.length;
        self.word = std.meta.stringToEnum(Word, text.slice() orelse "");
    }
};

fn identity(item_type: *const Named, id: *const Named) Failure!struct { kind: codec_abi.OutputKind, id: Range } {
    const kind = Word.kind(try (try item_type.required()).compared()) orelse return error.UnsupportedItemType;
    const named = try id.required();
    if (named.shape != .string) return error.ExpectedJsonString;
    if (named.decoded == 0) return error.EmptyProviderIdentity;
    return .{ .kind = kind, .id = named.range };
}

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

pub fn finish(stream: *const Stream) ?Reason {
    return if (stream.completed) null else .provider_connection_closed;
}

pub const InterpretScratch = struct {
    reader: json.Reader,
    type: ?EventType,
    path: [6]Key,
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
    failed: codec_abi.Failed,

    fn init(self: *InterpretScratch, operation: codec_abi.Operation) void {
        self.type = null;
        self.path = @splat(.other);
        self.in_item = false;
        inline for (.{ &self.outer.values, &self.nested.values, &self.response.values, &self.response_error.values, &self.item.values, &self.usage.values }) |values| {
            for (values) |*member| member.count = 0;
        }
        self.details_reason.count = 0;
        self.cached.count = 0;
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

/// Responses events are whole in one SSE event: the data passes through unchanged.
pub fn normalize(stream: *Stream, data: []const u8, out: *codec_abi.Normalized) void {
    _ = stream;
    out.* = .{ .whole = true };
    out.copy(.{ .start = 0, .length = data.len });
}

pub fn interpretEvent(stream: *Stream, scratch: *InterpretScratch, data: []const u8) codec_abi.Event {
    var at: codec_abi.At = .{ .stage = .stream, .output_index = null };
    const what = verdict(stream, scratch, data, &at) catch |err| return .{ .at = at, .what = .{ .failed = failedOf(scratch, err) } };
    return .{ .at = at, .what = what };
}

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
    const announced = try identity(scratch.item.getPtrConst(.type), scratch.item.getPtrConst(.id));
    stream.added_active = true;
    return .{ .added = .{ .kind = announced.kind, .id = announced.id } };
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
        range.* = members.getPtrConst(name).range;
    };
    const phase_member = members.getPtrConst(.phase);
    const phase: codec_abi.Phase = if (kind != .message or phase_member.count == 0 or phase_member.shape != .string) .unphased else if (phase_member.word == .commentary) .commentary else if (phase_member.word == .final_answer) .final_answer else .unphased;
    stream.item_count += 1;
    stream.added_active = false;
    return .{
        .item = .{
            .kind = kind,
            .phase = phase,
            .answer_phase = judge.answerPhase(),
            .omit_reasoning_text = omit_reasoning_text,
            .whole = item.range,
            .id = members.getPtrConst(.id).range,
            .call = call,
            .members = .{ .offset = item.range.start, .scope = .item, .kind = kind, .phase = phase, .array = .none, .text = .{ .start = 0, .length = 0 } },
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
        .output = .{ .offset = 0, .scope = .output, .kind = .message, .phase = .unphased, .array = .none, .text = .{ .start = 0, .length = 0 } },
        .usage = .absent,
    };
    responseCheck(scratch, &completed) catch |err| {
        completed.check = reasonOf(err);
        return .{ .completed = completed };
    };
    completed.usage = usage(scratch) catch |err| .{ .failed = reasonOf(err) };
    return .{ .completed = completed };
}

fn responseCheck(scratch: *const InterpretScratch, completed: *codec_abi.Completed) Failure!void {
    const response = try scratch.outer.getPtrConst(.response).required();
    if (response.shape != .object) return error.UnexpectedJsonDelimiter;
    const members = &scratch.response;
    if (try (try members.getPtrConst(.status).required()).compared() != .completed) return error.UnsupportedResponseStatus;
    const id = try members.getPtrConst(.id).required();
    _ = try id.compared();
    if (id.decoded == 0) return error.EmptyProviderIdentity;
    completed.response_id = id.range;
    if (try members.getPtrConst(.model).get()) |model| if (model.shape != .null_value) {
        _ = try model.compared();
        if (model.decoded == 0) return error.EmptyProviderIdentity;
        completed.served_model = model.range;
    };
    const output = try members.getPtrConst(.output).required();
    if (output.shape != .array) return error.UnexpectedJsonDelimiter;
    completed.output.offset = output.range.start;
}

fn usage(scratch: *const InterpretScratch) Failure!@FieldType(codec_abi.Completed, "usage") {
    const report = try scratch.response.getPtrConst(.usage).get() orelse return .absent;
    if (report.shape == .null_value) return .absent;
    if (report.shape != .object) return error.UnexpectedJsonDelimiter;
    return .{ .report = .{ .whole = report.range, .counts = usageCounts(scratch) } };
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
    var code_text: json.Text = .{ .length = 0 };
    var kind_text: json.Text = .{ .length = 0 };
    const code_authority: Authority = if (try fields.code.get()) |value| textAuthority(data, value, &code_text) else .absent;
    const kind_authority: Authority = if (fields.type) |kind| if (kind.get() catch null) |value| textAuthority(data, value, &kind_text) else .absent else .absent;
    const word = refusalWord(code_authority, kind_authority) orelse return error.ReportedProviderFailure;
    if (std.mem.eql(u8, word, "context_length_exceeded")) return error.ContextOverflow;
    failed.refusal = refusalOf(word);
    return error.ReportedProviderFailure;
}

/// A string member's text, decoded into `text` (which the caller keeps alive while the result is used).
fn textAuthority(data: []const u8, member: *const Named, text: *json.Text) Authority {
    if (member.shape != .string) return .absent;
    if (member.decoded > json.max_text_bytes) return .unreadable;
    json.decode(slice(data, member.range), text);
    return .{ .text = text.slice() orelse return .unreadable };
}

const Report = struct { code: *const Named, type: ?*const Named, message: *const Named, detail: *const Named };

fn reportRange(member: *const Named) codec_abi.ReportRange {
    return .{ .escape = .json_string_v1, .start = member.range.start, .length = member.range.length };
}

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

pub fn nextMember(data: []const u8, cursor: *codec_abi.Cursor) ?codec_abi.Member {
    while (true) switch (cursor.scope) {
        .item => {
            const member = nextKey(data, &cursor.offset) orelse return null;
            switch (itemMember(data, cursor, &member)) {
                .parts => |array| {
                    cursor.scope = .array;
                    cursor.array = array;
                },
                .neutral => cursor.offset = json.valueEnd(data, @intCast(member.value)),
                .bag => return .{ .bag = bagMember(data, &member, cursor) },
            }
        },
        .array => {
            const start = nextElement(data, &cursor.offset) orelse {
                cursor.scope = .item;
                continue;
            };
            const part = partOf(data, start, cursor.kind, cursor.array);
            cursor.scope = .part;
            cursor.offset = start;
            cursor.text = part.member;
            return .{ .part = .{ .array = cursor.array, .kind = part.kind, .text = part.text } };
        },
        .part => {
            const member = nextKey(data, &cursor.offset) orelse {
                cursor.scope = .array;
                return .part_end;
            };
            if (member.start == cursor.text.start) {
                cursor.offset = cursor.text.start + cursor.text.length;
                continue;
            }
            const bag = bagMember(data, &member, cursor);
            if (json.decodedTag(enum { type }, slice(data, member.key)) == null) return .{ .bag = bag };
        },
        .output => {
            const start = nextElement(data, &cursor.offset) orelse return null;
            return terminalOf(data, start, &cursor.offset) catch |err| .{ .terminal_failed = reasonOf(err) };
        },
    };
}

const ObjectMember = struct { key: Range, start: u64, value: u64 };

fn nextKey(data: []const u8, offset: *u64) ?ObjectMember {
    var at = json.skipSpace(data, @intCast(offset.*));
    if (data[at] != '}') at = json.skipSpace(data, at + 1);
    if (data[at] == '}') {
        offset.* = at + 1;
        return null;
    }
    const name = json.stringAt(data, at);
    const value = json.skipSpace(data, json.skipSpace(data, name.end) + 1);
    offset.* = value;
    return .{ .key = name.contents, .start = at, .value = value };
}

fn bagMember(data: []const u8, member: *const ObjectMember, cursor: *codec_abi.Cursor) Range {
    cursor.offset = json.valueEnd(data, @intCast(member.value));
    return .{ .start = member.start, .length = cursor.offset - member.start };
}

fn nextElement(data: []const u8, offset: *u64) ?u64 {
    var at = json.skipSpace(data, @intCast(offset.*));
    if (data[at] != ']') at = json.skipSpace(data, at + 1);
    if (data[at] == ']') {
        offset.* = at + 1;
        return null;
    }
    return at;
}

fn slice(data: []const u8, range: Range) []const u8 {
    return data[@intCast(range.start)..][0..@intCast(range.length)];
}

fn itemMember(data: []const u8, cursor: *const codec_abi.Cursor, member: *const ObjectMember) union(enum) { neutral, bag, parts: codec_abi.PartArray } {
    const Name = enum { type, created_by, role, phase, content, summary, name, call_id, arguments };
    const name = json.decodedTag(Name, slice(data, member.key)) orelse return .bag;
    if (name == .type or name == .created_by) return .neutral;
    const array: codec_abi.PartArray = switch (cursor.kind) {
        .message => switch (name) {
            .role => return .neutral,
            .phase => return if (cursor.phase == .unphased) .bag else .neutral,
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
        .compaction, .web_search_call => return .bag,
    };
    const value: usize = @intCast(member.value);
    if (data[value] != '[' or data[json.skipSpace(data, value + 1)] == ']') return .bag;
    return .{ .parts = array };
}

pub fn hostedCall(data: []const u8, item: *const codec_abi.OutputItem) codec_abi.HostedCall {
    std.debug.assert(item.kind == .web_search_call);
    var call: codec_abi.HostedCall = .{};
    var action: ?u64 = null;
    var status = false;
    var offset = item.whole.start;
    while (nextKey(data, &offset)) |member| {
        const value = json.valueAt(data, @intCast(member.value));
        offset = value.end;
        switch (json.decodedTag(enum { status, action }, slice(data, member.key)) orelse continue) {
            .status => if (!status) {
                status = true;
                call.failed = if (value.string) |text| json.decodedTag(enum { failed }, slice(data, text)) != null else false;
            },
            .action => if (action == null) {
                action = member.value;
            },
        }
    }
    const start = action orelse return call;
    if (data[@intCast(start)] != '{') return call;
    const Strings = struct { type: ?Range = null, query: ?Range = null, url: ?Range = null, pattern: ?Range = null };
    var strings: Strings = .{};
    var queries: ?u64 = null;
    offset = start;
    while (nextKey(data, &offset)) |member| {
        const value = json.valueAt(data, @intCast(member.value));
        offset = value.end;
        if (data[@intCast(member.value)] == '[' and json.decodedTag(enum { queries }, slice(data, member.key)) != null) {
            if (queries == null) queries = member.value;
            continue;
        }
        const string = value.string orelse continue;
        const field = switch (json.decodedTag(std.meta.FieldEnum(Strings), slice(data, member.key)) orelse continue) {
            .type => &strings.type,
            .query => &strings.query,
            .url => &strings.url,
            .pattern => &strings.pattern,
        };
        if (field.* == null) field.* = string;
    }
    const kind = strings.type orelse return call;
    switch (json.decodedTag(enum { search, open_page, find_in_page }, slice(data, kind)) orelse return call) {
        .search => {
            call.action = .search;
            call.target = strings.query;
            call.queries = queries;
        },
        .open_page => {
            call.action = .open_page;
            call.target = strings.url;
        },
        .find_in_page => {
            call.action = .find_in_page;
            call.target = strings.url;
            call.pattern = strings.pattern;
        },
    }
    return call;
}

/// The next target of `call` in provider order, or null at the end. A search names its `query` first, then each string
/// of `queries`; a first string of `queries` equal to `query` is the same search and is skipped.
pub fn nextHostedTarget(data: []const u8, call: *const codec_abi.HostedCall, cursor: *codec_abi.HostedCursor) ?Range {
    while (true) switch (cursor.state) {
        .single => {
            cursor.state = if (call.queries) |at| queries: {
                cursor.at = at;
                break :queries .queries;
            } else .done;
            if (call.target) |target| return target;
        },
        .queries => {
            const at = nextElement(data, &cursor.at) orelse {
                cursor.state = .done;
                continue;
            };
            const value = json.valueAt(data, @intCast(at));
            cursor.at = value.end;
            const string = value.string orelse continue;
            const repeats = cursor.first and if (call.target) |target| std.mem.eql(u8, slice(data, target), slice(data, string)) else false;
            cursor.first = false;
            if (!repeats) return string;
        },
        .done => return null,
    };
}

fn partOf(data: []const u8, start: u64, kind: codec_abi.OutputKind, array: codec_abi.PartArray) struct { kind: codec_abi.PartKind, text: Range, member: Range } {
    const Text = struct { contents: ?Range = null, member: Range = .{ .start = 0, .length = 0 } };
    var word: ?Word = null;
    var text: Text = .{};
    var refusal: Text = .{};
    var offset = start;
    while (nextKey(data, &offset)) |member| {
        const value = json.valueAt(data, @intCast(member.value));
        offset = value.end;
        const found: Text = .{ .contents = value.string, .member = .{ .start = member.start, .length = value.end - member.start } };
        switch (json.decodedTag(enum { type, text, refusal }, slice(data, member.key)) orelse continue) {
            .type => word = json.decodedTag(Word, slice(data, value.string.?)),
            .text => text = found,
            .refusal => refusal = found,
        }
    }
    const part = partKind(kind, array, word).?;
    const chosen = if (part == .refusal) refusal else text;
    return .{ .kind = part, .text = chosen.contents.?, .member = chosen.member };
}

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

fn terminalOf(data: []const u8, start: u64, offset: *u64) Failure!codec_abi.Member {
    if (data[@intCast(start)] != '{') {
        offset.* = json.valueEnd(data, @intCast(start));
        return error.UnexpectedJsonDelimiter;
    }
    var found: std.enums.EnumArray(enum { type, id }, Named) = .initFill(.{});
    offset.* = start;
    while (nextKey(data, offset)) |member| {
        const value = json.valueAt(data, @intCast(member.value));
        offset.* = value.end;
        const name = json.decodedTag(@TypeOf(found).Key, slice(data, member.key)) orelse continue;
        found.getPtr(name).walked(data, @intCast(member.value), value);
    }
    const named = try identity(found.getPtrConst(.type), found.getPtrConst(.id));
    return .{ .terminal = .{ .kind = named.kind, .whole = .{ .start = start, .length = offset.* - start }, .id = named.id } };
}

test "an encoder resumed from a carry separates its next input item only after an earlier one" {
    const header: ItemHeader = .{ .item = .tool_result, .handles = 0b11 };
    var pieces: Pieces = .{ .len = 0 };
    var first: Encoder = .{ .carry = initial(.one, null) };
    try first.encodeItem(&header, &pieces);
    try std.testing.expect(!std.mem.eql(u8, pieces.items[0].literal, ","));
    var next: Encoder = .{ .carry = first.carry };
    try next.encodeItem(&header, &pieces);
    try std.testing.expectEqualStrings(",", pieces.items[0].literal);
}

test "every item at its longest fits max_pieces and names only handles it has" {
    const Case = struct { item: codec_abi.Item, handles: []const u8 };
    var cases: [80]Case = undefined;
    var count: usize = 0;
    for ([_]?codec_abi.Effort{null} ++ std.enums.values(codec_abi.Effort)) |effort| {
        cases[count] = .{ .item = .{ .settings = .{ .effort = effort, .session_affinity = @splat(0xff), .model_length = 0 } }, .handles = &.{0b1} };
        count += 1;
    }
    for ([_]?codec_abi.Effort{null} ++ std.enums.values(codec_abi.Effort)) |effort| {
        cases[count] = .{ .item = .{ .operation = effort }, .handles = &.{0} };
        count += 1;
        if (effort) |value| {
            cases[count] = .{ .item = .{ .effort_update = value }, .handles = &.{0} };
            count += 1;
        }
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
        .{ .item = .{ .message = .instruction }, .handles = &.{0b1} },
        .{ .item = .output_close, .handles = &.{ 0, 0b1 } },
        .{ .item = .tool_result, .handles = &.{0b11} },
        .{ .item = .history_start, .handles = &.{0} },
        .{ .item = .history_end, .handles = &.{0} },
        .{ .item = .compaction_trigger, .handles = &.{0} },
        .{ .item = .tools_start, .handles = &.{0} },
        .{ .item = .tool, .handles = &.{0b111} },
        .{ .item = .declare_open, .handles = &.{0} },
        .{ .item = .declared_tool, .handles = &.{0b111} },
        .{ .item = .declare_close, .handles = &.{0} },
        .{ .item = .text_format, .handles = &.{ 0, 0b1 } },
        .{ .item = .request_end, .handles = &.{0} },
    }) |case| {
        cases[count] = case;
        count += 1;
    }
    var longest: u8 = 0;
    for (cases[0..count]) |case| for (case.handles) |handles| {
        for ([_]bool{ false, true }) |comma| for ([_]@TypeOf(@as(Carry, undefined).input){ .unopened, .first, .comma, .owed }) |input| for ([_]bool{ false, true }) |omit| for (std.enums.values(codec_abi.PartArray)) |array| for (std.enums.values(Version)) |version| {
            var encoder: Encoder = .{ .carry = .{ .input = input, .version = version, .effort = .low }, .tool_comma = comma, .omit_reasoning_text = omit, .array = array };
            const header: ItemHeader = .{ .item = case.item, .handles = handles };
            var pieces: Pieces = .{ .len = 0 };
            const declined = switch (case.item) {
                .operation => |value| value == null and version == .two,
                .tool => version != .one,
                .declare_open, .declared_tool, .declare_close => version == .one,
                .tools_start => input == .owed,
                else => false,
            };
            if (declined) {
                try std.testing.expectError(error.Declined, encoder.encodeItem(&header, &pieces));
                continue;
            }
            try encoder.encodeItem(&header, &pieces);
            longest = @max(longest, pieces.len);
            for (pieces.slice()) |piece| switch (piece) {
                .literal => |bytes| try std.testing.expect(bytes.len != 0),
                .content => |content| try std.testing.expect(header.has(content.handle)),
                .base64 => |handle| try std.testing.expect(header.has(handle)),
            };
        };
    };
    try std.testing.expectEqual(codec_abi.max_pieces, longest);
}

test "CM-43 provider effort encoding" {
    for (std.enums.values(Version)) |version| {
        for ([_]?codec_abi.Effort{null} ++ std.enums.values(codec_abi.Effort)) |effort| {
            var encoder: Encoder = .{ .carry = initial(version, effort) };
            const settings: codec_abi.Settings = .{ .effort = effort, .starting_effort = effort, .session_affinity = @splat(0), .model_length = 0 };
            const header: ItemHeader = .{ .item = .{ .settings = settings }, .handles = 0b1 };
            var encoded: Pieces = .{ .len = 0 };
            try encoder.encodeItem(&header, &encoded);
            var found: ?[]const u8 = null;
            for (encoded.slice()) |piece| switch (piece) {
                .literal => |bytes| if (std.mem.indexOf(u8, bytes, "\"reasoning\"") != null) {
                    try std.testing.expect(found == null);
                    found = bytes;
                },
                else => {},
            };
            if (effort) |value| {
                var buffer: [64]u8 = undefined;
                const expected = try std.fmt.bufPrint(&buffer, ",\"reasoning\":{{\"effort\":\"{s}\"}}", .{@tagName(value)});
                try std.testing.expectEqualStrings(expected, found orelse return error.MissingReasoning);
            } else try std.testing.expect(found == null);
        }
    }

    var pieces: Pieces = .{ .len = 0 };
    const settings: codec_abi.Settings = .{ .effort = .high, .starting_effort = .low, .session_affinity = @splat(0), .model_length = 0 };
    const header: ItemHeader = .{ .item = .{ .settings = settings }, .handles = 0b1 };
    var two: Encoder = .{ .carry = initial(.two, .low) };
    try two.encodeItem(&header, &pieces);
    try std.testing.expectEqualStrings(",\"reasoning\":{\"effort\":\"low\"}", pieces.items[pieces.len - 1].literal);
    var one: Encoder = .{ .carry = initial(.one, .low) };
    try one.encodeItem(&header, &pieces);
    try std.testing.expectEqualStrings(",\"reasoning\":{\"effort\":\"high\"}", pieces.items[pieces.len - 1].literal);

    two.carry.input = .first;
    try two.encodeItem(&.{ .item = .{ .operation = .low }, .handles = 0 }, &pieces);
    try std.testing.expectEqual(@as(u8, 0), pieces.len);
    try two.encodeItem(&.{ .item = .{ .operation = .high }, .handles = 0 }, &pieces);
    try std.testing.expectEqual(@as(u8, 1), pieces.len);
    try std.testing.expectEqualStrings("{\"type\":\"configuration_update\",\"reasoning\":{\"effort\":\"high\"}}", pieces.items[0].literal);
    try std.testing.expectEqual(@as(?codec_abi.Effort, .high), two.carry.effort);
    try two.encodeItem(&.{ .item = .{ .operation = .high }, .handles = 0 }, &pieces);
    try std.testing.expectEqual(@as(u8, 0), pieces.len);
    try one.encodeItem(&.{ .item = .{ .operation = .high }, .handles = 0 }, &pieces);
    try std.testing.expectEqual(@as(u8, 0), pieces.len);
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
        "{\"error\":{\"type\":\"usage_limit_reached\",\"message\":\"The usage limit has been reached\",\"plan_type\":\"pro\",\"resets_at\":1795336193,\"eligible_promo\":null,\"resets_in_seconds\":444255}}",
        "",
    };
    const same = struct {
        fn body(expected: *const codec_abi.ErrorBody, actual: *const codec_abi.ErrorBody) !void {
            try std.testing.expectEqual(expected.context_overflow, actual.context_overflow);
            try std.testing.expectEqual(expected.refusal, actual.refusal);
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
    try std.testing.expectEqual(codec_abi.Refusal.quota, fresh.refusal.?);
    try std.testing.expectEqual(@as(?u64, 1_800_000_123), fresh.resets_at);
    try std.testing.expectEqualStrings("Out.", bodies[0][fresh.report.message.?.start..][0..fresh.report.message.?.length]);
}

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
                if (failed.refusal) |refusal| try out.print(" refusal {t}", .{refusal});
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
        \\failed reported_provider_failure refusal policy code 73+12 message 98+2
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
    var again_buffer: [8192]u8 = undefined;
    var again: std.Io.Writer = .fixed(&again_buffer);
    try describeForTesting(&events, &testing_scratch, &again);
    try std.testing.expectEqualStrings(expected.buffered(), again.buffered());
    try std.testing.expect(std.mem.indexOf(u8, expected.buffered(), "  part content output_text ok\n  bag \"annotations\":[]\n  part_end\n") != null);
}

test "a web search call reads as its action, its targets, its pattern and its outcome" {
    const Case = struct { item: []const u8, action: codec_abi.HostedAction, targets: []const []const u8 = &.{}, pattern: ?[]const u8 = null, failed: bool = false };
    for ([_]Case{
        .{ .item = "{\"type\":\"web_search_call\",\"id\":\"ws\",\"status\":\"completed\",\"action\":{\"type\":\"search\",\"query\":\"zig \\\"io\\\"\",\"queries\":[\"zig \\\"io\\\"\"]}}", .action = .search, .targets = &.{"zig \\\"io\\\""} },
        .{ .item = "{ \"action\" : { \"url\" : \"https://a.b\" , \"type\" : \"open_page\" } , \"status\" : \"failed\" }", .action = .open_page, .targets = &.{"https://a.b"}, .failed = true },
        .{ .item = "{\"action\":{\"type\":\"find_in_page\",\"url\":\"u\",\"pattern\":\"p\",\"pattern\":\"q\"},\"action\":{\"type\":\"search\"}}", .action = .find_in_page, .targets = &.{"u"}, .pattern = "p" },
        .{ .item = "{\"action\":{\"type\":\"search\",\"query\":7}}", .action = .search },
        // Every string of `queries`, in provider order.
        .{ .item = "{\"action\":{\"type\":\"search\",\"queries\":[ \"first\" , \"second\", \"third\" ]}}", .action = .search, .targets = &.{ "first", "second", "third" } },
        // A `query` comes first and its repeat at the head of `queries` is the same search.
        .{ .item = "{\"action\":{\"type\":\"search\",\"queries\":[\"a\",\"b\"],\"query\":\"a\"}}", .action = .search, .targets = &.{ "a", "b" } },
        .{ .item = "{\"action\":{\"type\":\"search\",\"query\":\"a\",\"queries\":[\"b\",\"a\"]}}", .action = .search, .targets = &.{ "a", "b", "a" } },
        .{ .item = "{\"action\":{\"type\":\"search\",\"queries\":[]}}", .action = .search },
        .{ .item = "{\"action\":{\"type\":\"search\",\"queries\":[7,\"late\",null,\"last\"]}}", .action = .search, .targets = &.{ "late", "last" } },
        .{ .item = "{\"action\":{\"type\":\"open_page\",\"url\":\"u\",\"queries\":[\"ignored\"]}}", .action = .open_page, .targets = &.{"u"} },
        .{ .item = "{\"action\":{\"type\":\"future\",\"query\":\"q\"},\"status\":\"completed\"}", .action = .none },
        .{ .item = "{\"action\":null,\"status\":null}", .action = .none },
        .{ .item = "{\"id\":\"ws\",\"status\":\"fail\\u0065d\"}", .action = .none, .failed = true },
    }) |case| {
        const item: codec_abi.OutputItem = .{
            .kind = .web_search_call,
            .phase = .unphased,
            .answer_phase = .unphased,
            .omit_reasoning_text = false,
            .whole = .{ .start = 0, .length = case.item.len },
            .id = .{ .start = 0, .length = 0 },
            .call = @splat(.{ .start = 0, .length = 0 }),
            .members = undefined,
        };
        const call = hostedCall(case.item, &item);
        try std.testing.expectEqual(case.action, call.action);
        try std.testing.expectEqual(case.failed, call.failed);
        var cursor: codec_abi.HostedCursor = .{};
        var count: usize = 0;
        while (nextHostedTarget(case.item, &call, &cursor)) |range| : (count += 1) {
            try std.testing.expect(count < case.targets.len);
            try std.testing.expectEqualStrings(case.targets[count], slice(case.item, range));
        }
        try std.testing.expectEqual(case.targets.len, count);
        try std.testing.expect(nextHostedTarget(case.item, &call, &cursor) == null);
        if (case.pattern) |text| try std.testing.expectEqualStrings(text, slice(case.item, call.pattern.?)) else try std.testing.expect(call.pattern == null);
    }
}

test "version two declares function tools in the history and keeps only provider-run tools at the top" {
    var pieces: Pieces = .{ .len = 0 };
    var two: Encoder = .{ .carry = .{ .input = .comma, .version = .two } };
    try two.encodeItem(&.{ .item = .declare_open, .handles = 0 }, &pieces);
    try std.testing.expectEqualStrings(",", pieces.items[0].literal);
    try std.testing.expectEqualStrings("{\"type\":\"additional_tools\",\"role\":\"developer\",\"tools\":[", pieces.items[1].literal);
    try two.encodeItem(&.{ .item = .declared_tool, .handles = 0b111 }, &pieces);
    try std.testing.expectEqualStrings("{\"type\":\"function\",\"name\":\"", pieces.items[0].literal);
    try two.encodeItem(&.{ .item = .declared_tool, .handles = 0b111 }, &pieces);
    try std.testing.expectEqualStrings(",", pieces.items[0].literal);
    try two.encodeItem(&.{ .item = .declare_close, .handles = 0 }, &pieces);
    try std.testing.expectEqualStrings("]}", pieces.items[0].literal);
    try two.encodeItem(&.{ .item = .tools_start, .handles = 0 }, &pieces);
    try two.encodeItem(&.{ .item = .web_search, .handles = 0 }, &pieces);
    try std.testing.expectEqualStrings("{\"type\":\"web_search\",\"external_web_access\":true}", pieces.items[0].literal);
    try std.testing.expectError(error.Declined, two.encodeItem(&.{ .item = .tool, .handles = 0b111 }, &pieces));
    var one: Encoder = .{ .carry = .{ .version = .one } };
    try std.testing.expectError(error.Declined, one.encodeItem(&.{ .item = .declare_open, .handles = 0 }, &pieces));
}

test "effort update refusal requires an unambiguous parameter and invalid request at a rejecting status" {
    const cases = [_]struct { status: u16 = 400, body: []const u8, refused: bool = false }{
        .{ .body = "{\"error\":{\"code\":\"unsupported_value\",\"param\":\"reasoning.effort\",\"message\":\"high is not supported\"}}", .refused = true },
        .{ .status = 422, .body = "{\"error\":{\"type\":\"invalid_request_error\",\"code\":null,\"param\":\"input[12].reasoning.effort\",\"message\":\"high is not supported\"}}", .refused = true },
        .{ .body = "{\"error\":{\"code\":\"invalid_value\",\"param\":\"input[3].type\",\"message\":\"configuration_update is not supported\"}}", .refused = true },
        .{ .body = "{\"error\":{\"code\":\"unsupported_value\",\"param\":\"temperature\",\"message\":\"high is not supported\"}}" },
        .{ .status = 500, .body = "{\"error\":{\"code\":\"unsupported_value\",\"param\":\"reasoning.effort\"}}" },
        .{ .status = 200, .body = "{\"error\":{\"code\":\"unsupported_value\",\"param\":\"reasoning.effort\"}}" },
        .{ .body = "{\"error\":{\"code\":\"other\",\"param\":\"reasoning.effort\"}}" },
        .{ .body = "{\"error\":{\"code\":\"invalid_value\",\"param\":null,\"message\":\"reasoning.effort high configuration_update unsupported\"}}" },
        .{ .body = "{\"error\":{\"code\":\"invalid_value\",\"param\":\"input[3].type\",\"message\":\"additional_tools is not supported\"}}" },
        .{ .body = "{\"error\":{\"code\":\"invalid_value\",\"param\":\"input[3].type\",\"message\":\"Invalid value: 'configuration_update'. Supported values: message\"}}", .refused = true },
        .{ .body = "{\"error\":{\"code\":\"invalid_value\",\"param\":\"input[3].type\",\"message\":\"Unsupported additional_tools; supported: configuration_update\"}}" },
        .{ .body = "{\"error\":{\"code\":\"invalid_value\",\"param\":\"input[x].reasoning.effort\"}}" },
        .{ .body = "{\"error\":{\"code\":\"invalid_value\",\"param\":\"reasoning.effort\",\"param\":\"reasoning.effort\"}}" },
        .{ .body = "{\"error\":{\"code\":\"invalid_value\",\"param\":\"reasoning.effort\"},\"later\":[1,]}" },
    };
    var scratch: ClassifyScratch = undefined;
    var found: codec_abi.ErrorBody = undefined;
    for (cases) |case| {
        classify(&scratch, case.body, &found);
        try std.testing.expectEqual(case.refused, effortChangeRefused(&scratch, case.status, case.body));
    }
}

test "CM-45 input boundary transitions cover each version and carry state" {
    const State = @TypeOf(@as(Carry, undefined).input);
    for (std.enums.values(Version)) |version| for (std.enums.values(State)) |state| {
        for ([_]codec_abi.Item{ .{ .message = .instruction }, .{ .message = .user }, .history_start, .tools_start }) |item| {
            var encoder: Encoder = .{ .carry = .{ .version = version, .input = state } };
            var pieces: Pieces = .{ .len = 0 };
            const header: ItemHeader = .{ .item = item, .handles = 1 };
            if (item == .tools_start and state == .owed) {
                try std.testing.expectError(error.Declined, encoder.encodeItem(&header, &pieces));
                continue;
            }
            try encoder.encodeItem(&header, &pieces);
            switch (item) {
                .message => |author| {
                    if (version == .one and state == .unopened and author == .instruction) {
                        try std.testing.expectEqualStrings(",\"instructions\":\"", pieces.items[0].literal);
                        try std.testing.expectEqual(State.first, encoder.carry.input);
                    } else {
                        if (state == .unopened) try std.testing.expectEqualStrings(",\"input\":[", pieces.items[0].literal);
                        if (state == .comma) try std.testing.expectEqualStrings(",", pieces.items[0].literal);
                        try std.testing.expectEqual(State.comma, encoder.carry.input);
                        const role_index: usize = if (state == .unopened or state == .comma) 1 else 0;
                        try std.testing.expect(std.mem.indexOf(u8, pieces.items[role_index].literal, if (author == .instruction) "\"developer\"" else "\"user\"") != null);
                    }
                },
                .history_start => {
                    try std.testing.expectEqual(switch (state) {
                        .unopened => State.first,
                        .comma => State.owed,
                        else => state,
                    }, encoder.carry.input);
                    switch (state) {
                        .unopened => try std.testing.expectEqualStrings(",\"input\":[", pieces.items[0].literal),
                        .comma => try std.testing.expectEqualStrings(",", pieces.items[0].literal),
                        .first, .owed => try std.testing.expectEqual(@as(u8, 0), pieces.len),
                    }
                },
                .tools_start => {
                    try std.testing.expectEqual(if (state == .unopened) State.first else state, encoder.carry.input);
                    if (state == .unopened) try std.testing.expectEqualStrings(",\"input\":[", pieces.items[0].literal);
                    try std.testing.expectEqualStrings("],\"tools\":[", pieces.items[pieces.len - 1].literal);
                },
                else => unreachable,
            }
        }
    };
}
