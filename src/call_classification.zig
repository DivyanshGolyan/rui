//! Classification and descriptions of tool calls over supplied sources.
const std = @import("std");
const codec_abi = @import("codec_abi.zig");
const core_tools = @import("message_agent_arguments.zig");
const Bounded = @import("bounded.zig").Bounded;
const session_id = @import("session_id.zig");
const tool_presentation = @import("tool_presentation.zig");
const tool_proposal = @import("tool_proposal.zig");
const utf8_validation = @import("utf8_validation.zig");
const records = @import("tool_record.zig");
const Record = records.Record;
const Tool = records.Tool;
const Offered = records.Offered;
const Description = records.Description;
const max_name_bytes = records.max_name_bytes;
const record = records.record;
const bash_record = records.bash_record;
const find_tools_record = records.find_tools_record;
const skill_record = records.skill_record;
const read_transcript_record = records.read_transcript_record;
const message_agent_record = records.message_agent_record;
const start_agent_record = records.start_agent_record;

/// One call, as `describe` needs it.
pub const Call = union(Tool) {
    /// Arguments the parser accepted, whose description it required.
    bash: *const BashArguments,
    /// The core checks its arguments when it runs the call.
    find_tools,
    message_agent: *const core_tools.MessageAgentArguments,
    read_transcript: ?Bounded(session_id.bytes),
    skill,
    start_agent,
    web_search: WebSearchCall,
};

/// What a web search call did: its action and the decoded bytes of its
/// strings, of which the first `WebSearchCall.excerpt_bytes` are enough.
/// A string Rui could not read is empty, since the line only shows it.
pub const WebSearchCall = struct {
    action: codec_abi.HostedAction,
    target: []const u8 = "",
    pattern: []const u8 = "",

    pub const excerpt_bytes = 2 * tool_presentation.max_description_bytes;
};

pub fn describe(call: Call) Description {
    const out: Description = switch (call) {
        .bash => |arguments| arguments.description,
        // The core writes its own tools' lines (D105).
        .message_agent => |arguments| blk: {
            var out: Description = .{};
            compose(&out, &.{ "Message ", "" }, &.{arguments.id.slice()});
            break :blk out;
        },
        .find_tools => blk: {
            var out: Description = .{};
            out.set("Find tools") catch unreachable;
            break :blk out;
        },
        .read_transcript => |id| blk: {
            var out: Description = .{};
            if (id) |target| compose(&out, &.{ "Read ", "'s transcript" }, &.{target.slice()}) else compose(&out, &.{"Read own transcript"}, &.{});
            break :blk out;
        },
        .skill => blk: {
            var out: Description = .{};
            out.set("Use skills") catch unreachable;
            break :blk out;
        },
        .start_agent => blk: {
            var out: Description = .{};
            out.set("Start an agent") catch unreachable;
            break :blk out;
        },
        .web_search => |search| describeWebSearch(search),
    };
    std.debug.assert(tool_presentation.ToolPresentation.validDescription(out.slice()));
    return out;
}

fn describeWebSearch(call: WebSearchCall) Description {
    var target_text: Excerpt = .{};
    var pattern_text: Excerpt = .{};
    target_text.read(call.target);
    pattern_text.read(call.pattern);
    var page = target_text.slice();
    if (call.action == .open_page or call.action == .find_in_page) {
        for ([_][]const u8{ "https://", "http://" }) |scheme| if (std.ascii.startsWithIgnoreCase(page, scheme)) {
            page = page[scheme.len..];
            break;
        };
        if (std.ascii.startsWithIgnoreCase(page, "www.")) page = page[4..];
    }
    const quoted = target_text.slice();
    const found = pattern_text.slice();
    var out: Description = .{};
    switch (call.action) {
        .search => if (quoted.len != 0) compose(&out, &.{ "Search “", "”" }, &.{quoted}) else compose(&out, &.{"Search the web"}, &.{}),
        .open_page => if (page.len != 0) compose(&out, &.{ "Open ", "" }, &.{page}) else compose(&out, &.{"Open a page"}, &.{}),
        .find_in_page => if (found.len != 0 and page.len != 0)
            compose(&out, &.{ "Find “", "” in ", "" }, &.{ found, page })
        else if (found.len != 0)
            compose(&out, &.{ "Find “", "”" }, &.{found})
        else if (page.len != 0)
            compose(&out, &.{ "Find in ", "" }, &.{page})
        else
            compose(&out, &.{"Find in a page"}, &.{}),
        .none => compose(&out, &.{"Search the web"}, &.{}),
    }
    return out;
}

/// The first bytes of a string, on one line: each line break, control and
/// other separator becomes a space, and runs of spaces and the ends are
/// trimmed. Enough is kept to fill a description.
const Excerpt = struct {
    bytes: [WebSearchCall.excerpt_bytes]u8 = undefined,
    len: usize = 0,

    fn read(self: *Excerpt, bytes: []const u8) void {
        const raw = bytes[0..@min(bytes.len, WebSearchCall.excerpt_bytes)];
        const length = raw.len;
        // A cut scalar at the end is dropped; anything else invalid means
        // the source was not what it claimed, and shows nothing.
        var valid = length;
        while (valid > 0 and !std.unicode.utf8ValidateSlice(raw[0..valid])) valid -= 1;
        if (length - valid > 3) return;
        var scalars = std.unicode.Utf8View.initUnchecked(raw[0..valid]).iterator();
        var space = false;
        while (scalars.nextCodepointSlice()) |encoded| {
            const scalar = std.unicode.utf8Decode(encoded) catch unreachable;
            const blank = scalar < 0x20 or scalar == 0x7f or switch (scalar) {
                ' ', 0x85, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
                else => false,
            };
            if (blank) {
                space = self.len != 0;
                continue;
            }
            if (space) self.append(" ");
            space = false;
            self.append(encoded);
        }
    }

    fn append(self: *Excerpt, encoded: []const u8) void {
        @memcpy(self.bytes[self.len..][0..encoded.len], encoded);
        self.len += encoded.len;
    }

    fn slice(self: *const Excerpt) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// `literals` around `values`, alternating and starting with a literal,
/// within the description bound: a value that does not fit is cut at a
/// scalar and ends in "…", and the first value yields room to the second
/// down to half of what the values share.
fn compose(out: *Description, comptime literals: []const []const u8, values: []const []const u8) void {
    std.debug.assert(literals.len == values.len + 1 or (values.len == 0 and literals.len == 1));
    comptime var fixed: usize = 0;
    inline for (literals) |literal| fixed += literal.len;
    const room = out.bytes.len - fixed;
    var widths: [2]usize = .{ 0, 0 };
    switch (values.len) {
        0 => {},
        1 => widths[0] = @min(values[0].len, room),
        2 => {
            widths[1] = @min(values[1].len, @max(room / 2, room -| values[0].len));
            widths[0] = @min(values[0].len, room - widths[1]);
        },
        else => unreachable,
    }
    var writer = std.Io.Writer.fixed(&out.bytes);
    inline for (literals, 0..) |literal, index| {
        writer.writeAll(literal) catch unreachable;
        if (index < values.len) writeCut(&writer, values[index], widths[@min(index, widths.len - 1)]);
    }
    out.len = writer.end;
}

/// `text` within `width` bytes: whole, or its scalars that fit and "…".
fn writeCut(writer: *std.Io.Writer, text: []const u8, width: usize) void {
    if (text.len <= width) return writer.writeAll(text) catch unreachable;
    const ellipsis = "…";
    var end = width -| ellipsis.len;
    while (end > 0 and (text[end] & 0xc0) == 0x80) end -= 1;
    // A cut after a word reads as the word's end, not a blank before "…".
    while (end > 0 and text[end - 1] == ' ') end -= 1;
    writer.writeAll(text[0..end]) catch unreachable;
    writer.writeAll(ellipsis) catch unreachable;
}

pub const BashArguments = struct {
    timeout_ms: ?u64 = null,
    description: Bounded(tool_presentation.max_description_bytes) = .{},
    stdin_present: bool = false,
};

pub const CallFacts = struct {
    /// The offered record the call names; null when it names none that
    /// Rui runs, so it is an unknown tool.
    // A small value: MCP calls synthesize only the matched name and owner,
    // borrowing the name from Offered instead of retaining full records.
    tool: ?Record,
    /// A call named bash's checked arguments, offered or not; null for any
    /// other name.
    bash: ?BashCheck,
    /// A call named message_agent's checked arguments, offered or not; null
    /// for any other name.
    message_agent: ?core_tools.MessageAgentCheck = null,
    /// Whether an unknown call names a tool the Session withdrew.
    removed: bool = false,
    invalid_mcp_arguments: bool = false,
    find_tools: bool = false,
    skill: bool = false,
    read_transcript: bool = false,
    transcript_id: ?Bounded(session_id.bytes) = null,

    /// The arguments of a bash call the parser accepted.
    pub fn bashArguments(self: *const CallFacts) ?*const BashArguments {
        // Captured by pointer: `&(self.bash orelse ...)` would point at a copy
        // that ends with this call.
        const check = if (self.bash) |*bash| bash else return null;
        return switch (check.*) {
            .accepted => |*accepted| accepted,
            .rejected => null,
        };
    }

    /// The arguments of a message_agent call the parser accepted.
    pub fn messageAgentArguments(self: *const CallFacts) ?*const core_tools.MessageAgentArguments {
        const check = if (self.message_agent) |*value| value else return null;
        return switch (check.*) {
            .accepted => |*accepted| accepted,
            .rejected => null,
        };
    }

    /// The line a call is shown as, when its arguments carry one.
    pub fn description(self: *const CallFacts) ?Description {
        if (self.bashArguments()) |arguments| return describe(.{ .bash = arguments });
        if (self.messageAgentArguments()) |arguments| return describe(.{ .message_agent = arguments });
        if (self.find_tools) return describe(.find_tools);
        if (self.skill) return describe(.skill);
        if (self.read_transcript) return describe(.{ .read_transcript = self.transcript_id });
        if (self.tool) |*selected| if (selected.runner() == .core and std.mem.eql(u8, selected.name, start_agent_record.name)) return describe(.start_agent);
        return null;
    }
};

/// Why a Bash call's arguments were rejected. Its text goes back to the
/// model as the call's result, so the model can correct the call: the
/// provider does not check arguments against the schema, Rui does.
pub const BashProblem = enum {
    malformed_json,
    unknown_field,
    duplicate_field,
    missing_cmd,
    missing_description,
    cmd_invalid,
    description_invalid,
    stdin_invalid,
    timeout_invalid,

    pub fn text(self: BashProblem) []const u8 {
        return switch (self) {
            .malformed_json => "the arguments are not one well-formed JSON object",
            .unknown_field => "only cmd, description, stdin and timeout_ms are accepted",
            .duplicate_field => "a field appears more than once",
            .missing_cmd => "cmd is required",
            .missing_description => "description is required",
            .cmd_invalid => "cmd must be a string of UTF-8 text with no NUL characters",
            .description_invalid => std.fmt.comptimePrint("description must be a nonblank, single-line string of UTF-8 text, at most {d} bytes", .{tool_presentation.max_description_bytes}),
            .stdin_invalid => "stdin must be a string of UTF-8 text",
            .timeout_invalid => std.fmt.comptimePrint("timeout_ms must be an integer from 1 to {d}", .{std.math.maxInt(i64)}),
        };
    }
};

/// Inspect certified decoded sources against the records the request
/// offered (D49). The caller retains the sources' storage and calls this
/// under the transaction that publishes the proposal and Action.
pub fn inspectCall(name_source: anytype, name_length: u64, arguments: anytype, offered: *const Offered) !CallFacts {
    var name: [max_name_bytes]u8 = undefined;
    var length: usize = 0;
    if (name_length <= name.len) {
        while (length < name_length) : (length += 1) name[length] = (try name_source.next()) orelse break;
    }
    const complete = name_length <= name.len and length == name_length and try name_source.next() == null;
    const named = complete and std.mem.eql(u8, name[0..length], bash_record.name);
    const finding = complete and std.mem.eql(u8, name[0..length], find_tools_record.name);
    const skill = complete and std.mem.eql(u8, name[0..length], skill_record.name);
    const transcript = complete and std.mem.eql(u8, name[0..length], read_transcript_record.name);
    const messaging = complete and std.mem.eql(u8, name[0..length], message_agent_record.name);
    // Provider-run tools return inside the reply, never as function calls.
    const provider = if (complete) if (records.builtIn(name[0..length])) |builtin| record(builtin).owner == .provider else false else false;
    const tool: ?Record = if (complete and !provider) if (offered.find(name[0..length])) |candidate|
        if (records.builtIn(candidate)) |builtin| record(builtin).* else .{ .name = candidate, .owner = .mcp }
    else
        null else null;
    const removed = tool == null and complete and !provider and offered.wasWithdrawn(name[0..length]);
    // A call's arguments are read whether or not it was offered, so a
    // rejected call keeps its description for presentation.
    var discard: Discard = .{};
    const runner = if (tool) |*selected| selected.runner() else null;
    return .{
        .tool = tool,
        .bash = if (named and (runner == null or runner == .bash)) try checkBashArguments(arguments) else null,
        .message_agent = if (messaging and (runner == null or runner == .core)) try core_tools.checkMessageAgent(arguments, &discard) else null,
        .removed = removed,
        .invalid_mcp_arguments = if (runner == .mcp) !try checkMcpArguments(arguments) else false,
        .read_transcript = transcript and (runner == null or runner == .core),
        .transcript_id = if (transcript and (runner == null or runner == .core)) try transcriptDescriptionId(arguments) else null,
        .find_tools = finding and (runner == null or runner == .core),
        .skill = skill and (runner == null or runner == .core),
    };
}

fn checkMcpArguments(source: anytype) !bool {
    const Json = @import("codecs/json.zig");
    const Ignore = struct {
        pub fn key(_: @This(), _: *Json.Reader, _: u8) void {}
        pub fn begin(_: @This(), _: *Json.Reader, _: Json.Kind, _: u8) void {}
        pub fn end(_: @This(), _: *Json.Reader, _: Json.Kind, _: u8) void {}
    };
    const Source = struct {
        inner: @TypeOf(source),
        pub fn peek(self: *@This()) !?u8 {
            return self.inner.peek();
        }
        pub fn take(self: *@This()) !u8 {
            return self.inner.take();
        }
    };
    var input: Source = .{ .inner = source };
    var reader: Json.Reader = undefined;
    reader.readSource(&input, Ignore{}) catch |err| {
        if (isBashDescriptorError(err)) return false;
        inline for (@typeInfo(Json.Error).error_set.error_names.?) |each| {
            if (err == @field(anyerror, each)) return false;
        }
        return err;
    };
    return true;
}

/// Presentation only, not settlement validation. Oversized, malformed or
/// unusual arguments still reach the runtime checker unchanged.
noinline fn transcriptDescriptionId(source: anytype) !?Bounded(session_id.bytes) {
    var memory: [256]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&memory);
    var scanner = std.json.Scanner.initStreaming(fixed.allocator());
    defer scanner.deinit();
    var chunk: [256]u8 = undefined;
    var ended = false;
    var depth: usize = 0;
    var key = true;
    var is_id = false;
    var text: Bounded(session_id.bytes) = .{};
    var fits = true;
    var id: ?Bounded(session_id.bytes) = null;
    while (true) {
        var token = scanner.next() catch |err| switch (err) {
            error.BufferUnderrun => {
                if (ended) return null;
                var length: usize = 0;
                while (length < chunk.len and try source.peek() != null) : (length += 1) chunk[length] = try source.take();
                if (length == 0) {
                    ended = true;
                    scanner.endInput();
                } else scanner.feedInput(chunk[0..length]);
                continue;
            },
            error.SyntaxError, error.UnexpectedEndOfInput, error.OutOfMemory => return null,
        };
        const piece: ?[]const u8 = switch (token) {
            .partial_string, .string => |bytes| bytes,
            .partial_string_escaped_1 => |*bytes| bytes,
            .partial_string_escaped_2 => |*bytes| bytes,
            .partial_string_escaped_3 => |*bytes| bytes,
            .partial_string_escaped_4 => |*bytes| bytes,
            else => null,
        };
        if (piece) |bytes| {
            if (depth == 1) {
                if (text.len + bytes.len > text.bytes.len) fits = false else {
                    @memcpy(text.bytes[text.len..][0..bytes.len], bytes);
                    text.len += bytes.len;
                }
                if (token == .string) {
                    if (key) {
                        is_id = fits and text.eql("id");
                    } else if (is_id) {
                        id = if (fits and session_id.valid(text.slice())) text else null;
                    }
                    key = !key;
                    text = .{};
                    fits = true;
                }
            }
            continue;
        }
        switch (token) {
            .object_begin, .array_begin => {
                if (depth == 0 and token != .object_begin) return null;
                if (depth == 1) key = true;
                depth += 1;
            },
            .object_end, .array_end => depth -= 1,
            .end_of_document => return id,
            else => if (depth == 1 and !key) {
                if (is_id) id = null;
                key = true;
            },
        }
    }
}

pub const removed_tool_result = "This tool was removed.";

/// A rejected call's result text, from `classifyCall`'s code for `facts`.
pub fn rejectionResult(code: tool_proposal.Rejection, facts: *const CallFacts, name: anytype, name_length: u64, name_digest: [32]u8, buffer: *[192]u8) ![]const u8 {
    switch (code) {
        .invalid_arguments => {
            if (facts.invalid_mcp_arguments) return std.fmt.bufPrint(buffer, "Invalid arguments for tool '{s}': the arguments are not one well-formed JSON object.", .{facts.tool.?.name});
            if (facts.message_agent) |check| return switch (check.rejected) {
                inline else => |value| "Invalid arguments for tool 'message_agent': " ++ comptime value.text() ++ ".",
            };
            return switch (facts.bash.?.rejected) {
                inline else => |value| "Invalid arguments for tool 'bash': " ++ comptime value.text() ++ ".",
            };
        },
        .unknown_tool => {
            if (facts.removed) return removed_tool_result;
            var prefix: [32]u8 = undefined;
            var prefix_length: usize = 0;
            while (prefix_length < prefix.len) {
                prefix[prefix_length] = (try name.next()) orelse break;
                prefix_length += 1;
            }
            while (!std.unicode.utf8ValidateSlice(prefix[0..prefix_length])) prefix_length -= 1;
            if (name_length <= prefix.len) return std.fmt.bufPrint(buffer, "Unknown tool: {s}.", .{prefix[0..prefix_length]});
            const digest_hex = std.fmt.bytesToHex(name_digest, .lower);
            return std.fmt.bufPrint(buffer, "Unknown tool: {s}… (name continues; Rui content digest {s}).", .{ prefix[0..prefix_length], &digest_hex });
        },
    }
}

/// Admission policy over adapter-certified call facts: a call to a tool
/// the request did not offer gets the rejected-call result and never runs
/// (D49), before its arguments are judged.
pub fn classifyCall(facts: *const CallFacts) ?tool_proposal.Rejection {
    if (facts.tool == null) return .unknown_tool;
    if (facts.invalid_mcp_arguments) return .invalid_arguments;
    if (facts.bash) |check| if (check == .rejected) return .invalid_arguments;
    if (facts.message_agent) |check| if (check == .rejected) return .invalid_arguments;
    return null;
}

pub fn validBashArguments(source: anytype) !bool {
    var discard: Discard = .{};
    return try parseBashArguments(source, &discard, &discard) != null;
}

pub fn inspectBashArguments(source: anytype) !?BashArguments {
    var discard: Discard = .{};
    return parseBashArguments(source, &discard, &discard);
}

pub fn writeBashCommand(source: anytype, writer: anytype) !bool {
    var discard: Discard = .{};
    return try parseBashArguments(source, writer, &discard) != null;
}

pub fn writeBashStdin(source: anytype, writer: anytype) !bool {
    var discard: Discard = .{};
    return try parseBashArguments(source, &discard, writer) != null;
}

pub const BashCheck = union(enum) {
    accepted: BashArguments,
    rejected: BashProblem,
};

pub fn checkBashArguments(source: anytype) !BashCheck {
    var discard: Discard = .{};
    return checkBash(source, &discard, &discard);
}

fn parseBashArguments(source: anytype, writer: anytype, input: anytype) !?BashArguments {
    return switch (try checkBash(source, writer, input)) {
        .accepted => |accepted| accepted,
        .rejected => null,
    };
}

fn checkBash(source: anytype, writer: anytype, input: anytype) !BashCheck {
    var parser: BashParser = .{};
    while (true) {
        const progress = parser.advance(source, writer, input, 4096) catch |err| {
            // A decoding failure outside a string's bytes.
            if (isBashDescriptorError(err)) return .{ .rejected = .malformed_json };
            return err;
        };
        switch (progress) {
            .pending => {},
            .invalid => |problem| return .{ .rejected = problem },
            .complete => |result| return .{ .accepted = result },
        }
    }
}

pub const BashParseProgress = union(enum) {
    pending,
    invalid: BashProblem,
    complete: BashArguments,
};

pub const BashParser = struct {
    const Phase = enum {
        object_start,
        key_start,
        string,
        escape,
        unicode,
        surrogate_backslash,
        surrogate_u,
        low_unicode,
        colon,
        value_start,
        timeout_digits,
        timeout_null,
        after_value,
        after_object,
    };
    const StringTarget = enum { key, command, description, stdin };
    const ValueTarget = enum { none, command, timeout, description, stdin };

    phase: Phase = .object_start,
    string_target: StringTarget = .key,
    value_target: ValueTarget = .none,
    key: Bounded(16) = .{},
    result: BashArguments = .{},
    has_command: bool = false,
    has_timeout: bool = false,
    has_description: bool = false,
    has_stdin: bool = false,
    timeout_value: u64 = 0,
    null_index: u3 = 0,
    unicode_value: u21 = 0,
    unicode_digits: u3 = 0,
    high_surrogate: u21 = 0,
    stdin_utf8: utf8_validation.State = .{},

    pub fn advance(self: *BashParser, source: anytype, writer: anytype, input: anytype, maximum_bytes: usize) !BashParseProgress {
        std.debug.assert(maximum_bytes != 0);
        var consumed: usize = 0;
        while (consumed < maximum_bytes) {
            const next = try source.peek() orelse return self.finishAtEof();
            if (self.phase == .timeout_digits and (next == '.' or next == 'e' or next == 'E')) return .{ .invalid = .timeout_invalid };
            if (self.phase == .timeout_digits and (next < '0' or next > '9')) {
                self.result.timeout_ms = self.timeout_value;
                self.has_timeout = true;
                self.phase = .after_value;
                continue;
            }
            _ = try source.take();
            consumed += 1;
            switch (self.phase) {
                .object_start => {
                    if (isSpace(next)) continue;
                    if (next != '{') return .{ .invalid = .malformed_json };
                    self.phase = .key_start;
                },
                .key_start => {
                    if (isSpace(next)) continue;
                    if (next != '"') return .{ .invalid = .malformed_json };
                    self.key.len = 0;
                    self.string_target = .key;
                    self.phase = .string;
                },
                .string => {
                    if (next == '"') {
                        switch (self.string_target) {
                            .key => {
                                self.value_target = if (self.key.eql("cmd"))
                                    .command
                                else if (self.key.eql("timeout_ms"))
                                    .timeout
                                else if (self.key.eql("description"))
                                    .description
                                else if (self.key.eql("stdin"))
                                    .stdin
                                else
                                    return .{ .invalid = .unknown_field };
                                self.phase = .colon;
                            },
                            .command => {
                                self.has_command = true;
                                self.phase = .after_value;
                            },
                            .stdin => {
                                if (!self.stdin_utf8.complete()) return .{ .invalid = .stdin_invalid };
                                self.has_stdin = true;
                                self.result.stdin_present = true;
                                self.phase = .after_value;
                            },
                            .description => {
                                if (!tool_presentation.ToolPresentation.validDescription(self.result.description.slice())) return .{ .invalid = .description_invalid };
                                self.has_description = true;
                                self.phase = .after_value;
                            },
                        }
                    } else if (next < 0x20) {
                        return .{ .invalid = .malformed_json };
                    } else if (next == '\\') {
                        self.phase = .escape;
                    } else {
                        self.emitString(writer, input, &.{next}) catch |err| return self.emitFailure(err);
                    }
                },
                .escape => {
                    const decoded: ?u8 = switch (next) {
                        '"' => '"',
                        '\\' => '\\',
                        '/' => '/',
                        'b' => 8,
                        'f' => 12,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        'u' => null,
                        else => return .{ .invalid = .malformed_json },
                    };
                    if (decoded) |byte| {
                        self.emitString(writer, input, &.{byte}) catch |err| return self.emitFailure(err);
                        self.phase = .string;
                    } else {
                        self.unicode_value = 0;
                        self.unicode_digits = 0;
                        self.phase = .unicode;
                    }
                },
                .unicode => {
                    self.unicode_value = self.unicode_value * 16 + (std.fmt.charToDigit(next, 16) catch return .{ .invalid = .malformed_json });
                    self.unicode_digits += 1;
                    if (self.unicode_digits == 4) {
                        if (self.unicode_value >= 0xd800 and self.unicode_value <= 0xdbff) {
                            self.high_surrogate = self.unicode_value;
                            self.phase = .surrogate_backslash;
                        } else {
                            if (self.unicode_value >= 0xdc00 and self.unicode_value <= 0xdfff) return .{ .invalid = self.stringProblem() };
                            if (!(self.emitScalar(writer, input, self.unicode_value) catch |err| return self.emitFailure(err))) return .{ .invalid = self.stringProblem() };
                            self.phase = .string;
                        }
                    }
                },
                .surrogate_backslash => {
                    if (next != '\\') return .{ .invalid = self.stringProblem() };
                    self.phase = .surrogate_u;
                },
                .surrogate_u => {
                    if (next != 'u') return .{ .invalid = if (std.mem.indexOfScalar(u8, "\"\\/bfnrt", next) != null) self.stringProblem() else .malformed_json };
                    self.unicode_value = 0;
                    self.unicode_digits = 0;
                    self.phase = .low_unicode;
                },
                .low_unicode => {
                    self.unicode_value = self.unicode_value * 16 + (std.fmt.charToDigit(next, 16) catch return .{ .invalid = .malformed_json });
                    self.unicode_digits += 1;
                    if (self.unicode_digits == 4) {
                        if (self.unicode_value < 0xdc00 or self.unicode_value > 0xdfff) return .{ .invalid = self.stringProblem() };
                        const scalar = 0x10000 + ((self.high_surrogate - 0xd800) << 10) +
                            (self.unicode_value - 0xdc00);
                        if (!(self.emitScalar(writer, input, scalar) catch |err| return self.emitFailure(err))) return .{ .invalid = self.stringProblem() };
                        self.phase = .string;
                    }
                },
                .colon => {
                    if (isSpace(next)) continue;
                    if (next != ':') return .{ .invalid = .malformed_json };
                    self.phase = .value_start;
                },
                .value_start => {
                    if (isSpace(next)) continue;
                    switch (self.value_target) {
                        .none => unreachable,
                        .command => {
                            if (self.has_command) return .{ .invalid = .duplicate_field };
                            if (next != '"') return .{ .invalid = .cmd_invalid };
                            self.string_target = .command;
                            self.phase = .string;
                        },
                        .description => {
                            if (self.has_description) return .{ .invalid = .duplicate_field };
                            if (next != '"') return .{ .invalid = .description_invalid };
                            self.string_target = .description;
                            self.phase = .string;
                        },
                        .stdin => {
                            if (self.has_stdin) return .{ .invalid = .duplicate_field };
                            if (next == '"') {
                                self.string_target = .stdin;
                                self.phase = .string;
                            } else if (next == 'n') {
                                self.null_index = 1;
                                self.phase = .timeout_null;
                            } else return .{ .invalid = .stdin_invalid };
                        },
                        .timeout => {
                            if (self.has_timeout) return .{ .invalid = .duplicate_field };
                            if (next == 'n') {
                                self.null_index = 1;
                                self.phase = .timeout_null;
                            } else {
                                if (next < '1' or next > '9') return .{ .invalid = .timeout_invalid };
                                self.timeout_value = next - '0';
                                self.phase = .timeout_digits;
                            }
                        },
                    }
                },
                .timeout_digits => {
                    self.timeout_value = std.math.mul(u64, self.timeout_value, 10) catch return .{ .invalid = .timeout_invalid };
                    self.timeout_value = std.math.add(u64, self.timeout_value, next - '0') catch return .{ .invalid = .timeout_invalid };
                    if (self.timeout_value > std.math.maxInt(i64)) return .{ .invalid = .timeout_invalid };
                },
                .timeout_null => {
                    if (next != "null"[self.null_index]) return .{ .invalid = if (self.value_target == .stdin) .stdin_invalid else .timeout_invalid };
                    self.null_index += 1;
                    if (self.null_index == "null".len) {
                        if (self.value_target == .stdin) {
                            self.has_stdin = true;
                        } else {
                            self.result.timeout_ms = null;
                            self.has_timeout = true;
                        }
                        self.phase = .after_value;
                    }
                },
                .after_value => {
                    if (isSpace(next)) continue;
                    if (next == ',') {
                        self.phase = .key_start;
                    } else if (next == '}') {
                        self.phase = .after_object;
                    } else return .{ .invalid = .malformed_json };
                },
                .after_object => if (!isSpace(next)) return .{ .invalid = .malformed_json },
            }
        }
        return .pending;
    }

    fn finishAtEof(self: *const BashParser) BashParseProgress {
        if (self.phase != .after_object) return .{ .invalid = .malformed_json };
        if (!self.has_command) return .{ .invalid = .missing_cmd };
        if (!self.has_description) return .{ .invalid = .missing_description };
        return .{ .complete = self.result };
    }

    /// A string's bytes that cannot be held or are not UTF-8 reject the
    /// call as that string's problem; any other failure is the caller's.
    fn emitFailure(self: *const BashParser, err: anyerror) !BashParseProgress {
        if (isBashDescriptorError(err)) return .{ .invalid = self.stringProblem() };
        return err;
    }

    /// What is wrong when the string being read cannot be decoded or held.
    fn stringProblem(self: *const BashParser) BashProblem {
        return switch (self.string_target) {
            // No accepted key is longer than a few bytes or needs escapes.
            .key => .unknown_field,
            .command => .cmd_invalid,
            .description => .description_invalid,
            .stdin => .stdin_invalid,
        };
    }

    fn emitString(self: *BashParser, writer: anytype, input: anytype, bytes: []const u8) !void {
        switch (self.string_target) {
            .key => try emit(&self.key, null, bytes),
            .command => try emit(null, writer, bytes),
            .stdin => {
                try self.stdin_utf8.feed(bytes);
                try input.writeAll(bytes);
            },
            .description => {
                const label = &self.result.description;
                if (bytes.len > label.bytes.len - label.len) return error.InvalidDescriptorShape;
                @memcpy(label.bytes[label.len..][0..bytes.len], bytes);
                label.len += bytes.len;
            },
        }
    }

    fn emitScalar(self: *BashParser, writer: anytype, input: anytype, scalar: u21) !bool {
        if (scalar == 0 and self.string_target != .stdin) return false;
        var encoded: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(scalar, &encoded) catch return false;
        try self.emitString(writer, input, encoded[0..count]);
        return true;
    }
};

fn isSpace(byte: u8) bool {
    return switch (byte) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

fn emit(destination: ?*Bounded(16), writer: anytype, bytes: []const u8) !void {
    if (destination) |value| {
        if (value.len + bytes.len > value.bytes.len) return error.InvalidDescriptorShape;
        @memcpy(value.bytes[value.len .. value.len + bytes.len], bytes);
        value.len += bytes.len;
    }
    if (@TypeOf(writer) != @TypeOf(null)) try writer.writeAll(bytes);
}

const Discard = struct {
    pub fn writeAll(_: *Discard, _: []const u8) !void {}
};

pub fn isBashDescriptorError(err: anyerror) bool {
    return switch (err) {
        error.InvalidDescriptorShape, error.InvalidUtf8 => true,
        else => false,
    };
}

test "MCP argument validation preserves source read failures" {
    const Source = struct {
        pub fn peek(_: *@This()) error{InjectedReadFailure}!?u8 {
            return error.InjectedReadFailure;
        }
        pub fn take(_: *@This()) error{InjectedReadFailure}!u8 {
            return error.InjectedReadFailure;
        }
    };
    var source: Source = .{};
    try std.testing.expectError(error.InjectedReadFailure, checkMcpArguments(&source));
}
