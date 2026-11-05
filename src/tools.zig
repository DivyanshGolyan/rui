const std = @import("std");
const protocol = @import("protocol.zig");
const codec_abi = @import("codec_abi.zig");
pub const core_tools = @import("core_tools.zig");

/// Bash receives the command as one `-c` argument. Linux rejects an
/// argument of 128 KiB including its NUL (MAX_ARG_STRLEN with 4 KiB pages),
/// and with a small stack rlimit the whole argv+environment shares a 128 KiB
/// floor; 8 KiB stays for the shell path, environment and pointers.
pub const bash_max_command_bytes: usize = 120 * 1024;
/// Reuse the command ceiling for optional decoded stdin in charged scratch.
pub const bash_max_stdin_bytes: usize = bash_max_command_bytes;

/// Who supplied a tool: D48's "owning server". Who runs it is derived
/// from this (D46): Rui runs its own tools and an MCP server's, which it
/// calls over HTTP; the provider runs its own.
pub const Owner = enum { rui, provider, mcp };

/// The longest MCP server name a record carries, in the tool-name grammar.
pub const max_server_bytes = protocol.max_tool_name_bytes;

/// One tool, as the model is told about it (D48). Request rendering and
/// call checking work from a list of these. A provider-run tool's
/// description and schema are the provider's own, so each codec names it
/// and its record carries neither.
pub const Record = struct {
    name: []const u8,
    description: []const u8 = "",
    /// A JSON Schema object, as JSON text.
    input_schema: []const u8 = "",
    owner: Owner,
    /// The MCP server that serves the tool, for an `.mcp` record only.
    server: []const u8 = "",

    pub fn runner(self: *const Record) Runner {
        return Runner.of(self);
    }
};

/// The longest function name a provider accepts (OpenAI: 64 characters);
/// a longer call name cannot match any record.
pub const max_name_bytes = protocol.max_tool_name_bytes;

/// The most tools one set offers.
pub const max_tools = protocol.max_tools;

/// A record's identity: its name, owner, server and the content digests
/// of its description and input schema. A tool that moves to another
/// server is another record.
pub fn recordDigest(member: *const Record) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hashField(&hash, "rui/tool-record/v1");
    hashField(&hash, member.name);
    hashField(&hash, @tagName(member.owner));
    hashField(&hash, member.server);
    hash.update(&protocol.contentDigest(member.description));
    hash.update(&protocol.contentDigest(member.input_schema));
    return hash.finalResult();
}

/// The identity of an ordered set of records, which the Store saves once:
/// its members' `recordDigest`s, in order.
pub const SetDigest = struct {
    hash: std.crypto.hash.sha2.Sha256,

    pub fn init() SetDigest {
        var out: SetDigest = .{ .hash = .init(.{}) };
        hashField(&out.hash, "rui/tool-set/v2");
        return out;
    }

    pub fn add(self: *SetDigest, member: *const [32]u8) void {
        self.hash.update(member);
    }

    pub fn final(self: *SetDigest) [32]u8 {
        return self.hash.finalResult();
    }
};

fn hashField(hash: *std.crypto.hash.sha2.Sha256, value: []const u8) void {
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, value.len, .big);
    hash.update(&length);
    hash.update(value);
}

/// The tools a Host offers, sorted by name with no name twice: what a
/// Session's tool names resolve against. The Store saves it as one set
/// when it opens, and a Session's set takes its members from that one.
/// Today the built-ins; MCP tools join it at Host start (M3a).
pub const Catalog = struct {
    records: []const Record,
    /// Each record's `recordDigest`, in the same order.
    digests: []const [32]u8,

    /// The index of the record named `name`.
    pub fn find(self: *const Catalog, name: []const u8) ?usize {
        var low: usize = 0;
        var high = self.records.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            switch (std.mem.order(u8, self.records[middle].name, name)) {
                .eq => return middle,
                .lt => low = middle + 1,
                .gt => high = middle,
            }
        }
        return null;
    }

    /// Whether the records are sorted by name, each named once, and each
    /// digest is its record's.
    pub fn valid(self: *const Catalog) bool {
        if (self.records.len != self.digests.len or self.records.len > max_catalog_records) return false;
        for (self.records, self.digests, 0..) |*each, digest, index| {
            if (!protocol.validToolName(each.name) or !validServer(each)) return false;
            if (index != 0 and std.mem.order(u8, self.records[index - 1].name, each.name) != .lt) return false;
            if (!std.mem.eql(u8, &digest, &recordDigest(each))) return false;
        }
        return true;
    }
};

/// An MCP record names its server, in the tool-name grammar; any other
/// record names none.
pub fn validServer(each: *const Record) bool {
    return if (each.owner == .mcp) protocol.validToolName(each.server) else each.server.len == 0;
}

/// The most records a Host's catalog holds; its saved set holds as many.
pub const max_catalog_records = 1024;

pub const bash_record: Record = .{
    .name = "bash",
    .owner = .rui,
    .description = "Run Bash on the local machine. Each call starts in the Session Workspace; relative paths resolve there, while absolute paths can access outside it. Start filesystem exploration there and broaden searches only as needed. Put text payloads in stdin, never inside cmd. Bash has no terminal: no one can type into a running call, so password prompts (sudo, including installers that run it) and interactive programs fail. When flags or stdin cannot answer a prompt, give the command to the user to run in their own terminal: before running it when you can tell it will prompt, otherwise after its first such failure. Do not retry it here.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"cmd\":{\"type\":\"string\"}," ++
        std.fmt.comptimePrint("\"stdin\":{{\"type\":\"string\",\"description\":\"Optional. Literal UTF-8 text, at most {d} decoded bytes, read exactly then EOF. Omitted, stdin is /dev/null.\"}},", .{bash_max_stdin_bytes}) ++
        "\"description\":{\"type\":\"string\",\"description\":\"A short human-facing activity label: base verb + concrete target + useful scope, in sentence case with no trailing punctuation. Describe the intended work, not its status, success or safety. Required, nonblank, single-line valid UTF-8, at most 100 decoded UTF-8 bytes. Aim for 40–60 characters; use more only for useful scope. Example: Run parser regression tests\"}," ++
        "\"timeout_ms\":{\"type\":\"integer\",\"description\":\"Optional. Omit it for the Host default unless the work needs a different budget. A positive integer replaces it with a total elapsed execution budget in milliseconds from process start; output does not reset it. Allow enough time for searches, builds and tests. Expiry ends the call through process-group termination, not a background handle; partial effects may remain.\",\"minimum\":1,\"maximum\":9223372036854775807}}," ++
        "\"required\":[\"cmd\",\"description\"],\"additionalProperties\":false}",
};

pub const message_agent_record: Record = .{
    .name = "message_agent",
    .owner = .rui,
    .description = core_tools.message_agent_description,
    .input_schema = core_tools.message_agent_schema,
};

pub const start_agent_record: Record = .{
    .name = "start_agent",
    .owner = .rui,
    .description = core_tools.start_agent_description,
    .input_schema = core_tools.start_agent_schema,
};

pub const web_search_record: Record = .{ .name = "web_search", .owner = .provider };

/// Who carries out an accepted call to a tool Rui owns, derived from its
/// name and never stored (D46): Bash runs as an Action process; a core tool
/// runs as a core command (D24).
pub const Runner = enum {
    bash,
    core,
    mcp,
    provider,

    pub fn of(tool: *const Record) Runner {
        if (tool.owner == .mcp) return .mcp;
        if (tool.owner == .provider) return .provider;
        return if (std.mem.eql(u8, tool.name, message_agent_record.name) or std.mem.eql(u8, tool.name, start_agent_record.name)) .core else .bash;
    }
};

/// The record of each tool `Tool` names: the text a new tool set saves.
/// Until the wire names tools by name, a Session's tools are a `ToolSet`
/// and this maps it.
pub fn record(tool: Tool) *const Record {
    return switch (tool) {
        .bash => &bash_record,
        .message_agent => &message_agent_record,
        .start_agent => &start_agent_record,
        .web_search => &web_search_record,
    };
}

/// The built-ins, as the catalog of a Host with no other tools.
pub const built_in: Catalog = .{ .records = &built_in_records, .digests = &built_in_digests };

const built_in_records = blk: {
    var out: [std.enums.values(Tool).len]Record = undefined;
    for (std.enums.values(Tool), &out) |tool, *each| each.* = record(tool).*;
    break :blk out;
};

const built_in_digests = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [built_in_records.len][32]u8 = undefined;
    for (&built_in_records, &out) |*each, *digest| digest.* = recordDigest(each);
    break :blk out;
};

test "the built-in catalog is valid and finds each built-in by name" {
    try std.testing.expect(built_in.valid());
    for (std.enums.values(Tool), 0..) |tool, index| try std.testing.expectEqual(@as(?usize, index), built_in.find(@tagName(tool)));
    try std.testing.expectEqual(@as(?usize, null), built_in.find("bas"));
    try std.testing.expectEqual(@as(?usize, null), built_in.find("edit"));
}

comptime {
    for (std.enums.values(Tool)) |tool| {
        const r = record(tool);
        if (!std.mem.eql(u8, r.name, @tagName(tool)) or r.name.len > max_name_bytes) @compileError("tool record name");
    }
}

/// The records a request offers, in a fixed order.
pub const Offered = struct {
    /// Borrowed batch names and membership flags, filled by the Store lookup.
    mcp_names: []const protocol.Bounded(max_name_bytes) = &.{},
    mcp_offered: []const bool = &.{},
    records: [std.enums.values(Tool).len]*const Record = undefined,
    len: usize = 0,
    /// The tools the Session offered at an earlier revision and this
    /// request does not: a call to one gets "This tool was removed." (D54).
    withdrawn: ToolSet = .empty,

    pub fn of(set: ToolSet) Offered {
        var out: Offered = .{};
        for (std.enums.values(Tool)) |tool| if (set.contains(tool)) {
            out.records[out.len] = record(tool);
            out.len += 1;
        };
        return out;
    }

    /// From a tools_mask the Store already checked.
    pub fn ofMask(mask: u8) Offered {
        var set: ToolSet = .empty;
        for (std.enums.values(Tool)) |tool| if (mask & toolBit(tool) != 0) set.insert(tool);
        return of(set);
    }

    pub fn slice(self: *const Offered) []const *const Record {
        return self.records[0..self.len];
    }

    /// `set`, with the tools of `ever` it lacks withdrawn.
    pub fn since(set: ToolSet, ever: ToolSet) Offered {
        var out = of(set);
        out.withdrawn = ever.differenceWith(set);
        return out;
    }
};

/// Every tool call is shown as one line, its description: what the call
/// set out to do, in the base-verb form of "Run parser tests". `describe`
/// is the one place a call becomes that line, and its switch covers every
/// tool, so a tool cannot join the catalog without one. A function tool
/// asks the model for it (Bash's required `description` argument); a tool
/// the provider hosts takes no arguments of ours, so its line is written
/// from what the provider reports the call did.
pub const Description = protocol.Bounded(protocol.max_tool_description_bytes);

/// One call, as `describe` needs it.
pub const Call = union(Tool) {
    /// Arguments the parser accepted, whose description it required.
    bash: *const BashArguments,
    message_agent: *const core_tools.MessageAgentArguments,
    /// The core checks its arguments when it runs the call.
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

    pub const excerpt_bytes = 2 * protocol.max_tool_description_bytes;
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
        .start_agent => blk: {
            var out: Description = .{};
            out.set("Start an agent") catch unreachable;
            break :blk out;
        },
        .web_search => |search| describeWebSearch(search),
    };
    std.debug.assert(protocol.ToolPresentation.validDescription(out.slice()));
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

test "a web search call's description says what it did, on one line, within the bound" {
    const repeat = struct {
        fn of(comptime text: []const u8, comptime count: usize) *const [text.len * count]u8 {
            comptime {
                var result: [text.len * count]u8 = undefined;
                for (0..count) |index| @memcpy(result[index * text.len ..][0..text.len], text);
                const final = result;
                return &final;
            }
        }
    }.of;
    const Case = struct { action: codec_abi.HostedAction, target: ?[]const u8 = null, pattern: ?[]const u8 = null, expected: []const u8 };
    const long = (comptime repeat("a", 120));
    for ([_]Case{
        .{ .action = .search, .target = "zig 0.17 release notes", .expected = "Search “zig 0.17 release notes”" },
        .{ .action = .search, .target = " \n\t ", .expected = "Search the web" },
        .{ .action = .search, .expected = "Search the web" },
        .{ .action = .search, .target = (comptime repeat("a", 83)) ++ " bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .expected = "Search “" ++ (comptime repeat("a", 83)) ++ "…”" },
        .{ .action = .none, .target = "ignored", .expected = "Search the web" },
        .{ .action = .search, .target = "  two\r\nlines\u{2028}here  ", .expected = "Search “two lines here”" },
        .{ .action = .open_page, .target = "https://www.ziglang.org/download/", .expected = "Open ziglang.org/download/" },
        .{ .action = .open_page, .target = "HTTP://example.com", .expected = "Open example.com" },
        .{ .action = .open_page, .expected = "Open a page" },
        .{ .action = .find_in_page, .target = "https://ziglang.org/notes", .pattern = "Io.Writer", .expected = "Find “Io.Writer” in ziglang.org/notes" },
        .{ .action = .find_in_page, .pattern = "Io.Writer", .expected = "Find “Io.Writer”" },
        .{ .action = .find_in_page, .target = "ziglang.org", .expected = "Find in ziglang.org" },
        .{ .action = .find_in_page, .expected = "Find in a page" },
        .{ .action = .search, .target = long, .expected = "Search “" ++ (comptime repeat("a", 84)) ++ "…”" },
        // A cut never splits a scalar.
        .{ .action = .search, .target = "a" ++ (comptime repeat("é", 60)), .expected = "Search “a" ++ (comptime repeat("é", 41)) ++ "…”" },
        // Two long values share the room; a short first one leaves the rest.
        .{ .action = .find_in_page, .target = long, .pattern = long, .expected = "Find “" ++ (comptime repeat("a", 40)) ++ "…” in " ++ (comptime repeat("a", 39)) ++ "…" },
        .{ .action = .find_in_page, .target = long, .pattern = "x", .expected = "Find “x” in " ++ (comptime repeat("a", 81)) ++ "…" },
        // Bytes that are not UTF-8 show nothing; a scalar cut at the
        // excerpt's end is dropped.
        .{ .action = .search, .target = "\xff\xfe\xfd\xfc", .expected = "Search the web" },
        .{ .action = .search, .target = "q\xe2\x82", .expected = "Search “q”" },
    }) |case| {
        const description = describe(.{ .web_search = .{ .action = case.action, .target = case.target orelse "", .pattern = case.pattern orelse "" } });
        try std.testing.expectEqualStrings(case.expected, description.slice());
        try std.testing.expect(description.slice().len <= protocol.max_tool_description_bytes);
    }
}

test "a Bash call is described by the description its arguments carry" {
    var arguments: BashArguments = .{};
    try arguments.description.set("Run parser tests");
    try std.testing.expectEqualStrings("Run parser tests", describe(.{ .bash = &arguments }).slice());
}

pub const BashArguments = struct {
    timeout_ms: ?u64 = null,
    description: protocol.Bounded(protocol.max_tool_description_bytes) = .{},
    stdin_present: bool = false,
};

/// The built-in tools; the wire owns their names.
pub const Tool = protocol.BuiltInTool;
pub const builtIn = protocol.builtInTool;

pub const ToolSet = std.EnumSet(Tool);

/// Persisted tools_mask bit shared by Store encoding and model preparation.
pub fn toolBit(tool: Tool) u8 {
    return switch (tool) {
        .bash => 1,
        .web_search => 2,
        .message_agent => 4,
        .start_agent => 8,
    };
}

/// Every tool's bit: the largest valid tools_mask.
pub const all_tools_mask: u8 = blk: {
    var mask: u8 = 0;
    for (std.enums.values(Tool)) |tool| mask |= toolBit(tool);
    break :blk mask;
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
            .description_invalid => std.fmt.comptimePrint("description must be a nonblank, single-line string of UTF-8 text, at most {d} bytes", .{protocol.max_tool_description_bytes}),
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
    const messaging = complete and std.mem.eql(u8, name[0..length], message_agent_record.name);
    var tool: ?Record = if (complete) if (offeredFunction(offered.slice(), name[0..length])) |candidate| candidate.* else null else null;
    if (complete) for (offered.mcp_names, offered.mcp_offered) |*candidate, was_offered| {
        if (was_offered and std.mem.eql(u8, candidate.slice(), name[0..length])) {
            tool = .{ .name = candidate.slice(), .owner = .mcp };
            break;
        }
    };
    const removed = tool == null and complete and withdrawnFunction(offered.withdrawn, name[0..length]);
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

/// The offered record a function call named `name` resolves to. A
/// provider-run tool comes back finished inside the reply, never as a
/// function call, so a call naming one is unknown.
fn offeredFunction(offered: []const *const Record, name: []const u8) ?*const Record {
    for (offered) |candidate| {
        if (candidate.owner != .provider and std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

/// Whether `name` is a function tool in `withdrawn`.
fn withdrawnFunction(withdrawn: ToolSet, name: []const u8) bool {
    var tools = withdrawn.iterator();
    while (tools.next()) |tool| {
        const candidate = record(tool);
        if (candidate.owner == .rui and std.mem.eql(u8, candidate.name, name)) return true;
    }
    return false;
}

pub const removed_tool_result = "This tool was removed.";

/// A rejected call's result text, from `classifyCall`'s code for `facts`.
pub fn rejectionResult(code: protocol.ProposalRejection, facts: *const CallFacts, name: anytype, name_length: u64, name_digest: [32]u8, buffer: *[192]u8) ![]const u8 {
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
pub fn classifyCall(facts: *const CallFacts) ?protocol.ProposalRejection {
    if (facts.tool == null) return .unknown_tool;
    if (facts.invalid_mcp_arguments) return .invalid_arguments;
    if (facts.bash) |check| if (check == .rejected) return .invalid_arguments;
    if (facts.message_agent) |check| if (check == .rejected) return .invalid_arguments;
    return null;
}

test "a call is checked against the offered records before its arguments" {
    const Source = struct {
        bytes: []const u8,
        index: usize = 0,
        fn next(self: *@This()) !?u8 {
            if (self.index == self.bytes.len) return null;
            defer self.index += 1;
            return self.bytes[self.index];
        }
    };
    const Case = struct { name: []const u8, arguments: []const u8, offered: ToolSet, expected: ?protocol.ProposalRejection, described: bool = false, ever: ToolSet = .empty, removed: bool = false };
    const valid = "{\"cmd\":\"true\",\"description\":\"Run true\"}";
    const bash_only = ToolSet.initOne(.bash);
    for ([_]Case{
        .{ .name = "bash", .arguments = valid, .offered = bash_only, .expected = null, .described = true },
        .{ .name = "bash", .arguments = "{}", .offered = bash_only, .expected = .invalid_arguments },
        // A Bash call that was not offered keeps its description.
        .{ .name = "bash", .arguments = valid, .offered = .empty, .expected = .unknown_tool, .described = true },
        .{ .name = "bash", .arguments = "{}", .offered = ToolSet.initOne(.web_search), .expected = .unknown_tool },
        // A provider-run tool never runs as a function call.
        .{ .name = "web_search", .arguments = "{}", .offered = .full, .expected = .unknown_tool },
        .{ .name = "bas", .arguments = valid, .offered = .full, .expected = .unknown_tool },
        .{ .name = "bashx", .arguments = valid, .offered = .full, .expected = .unknown_tool },
        .{ .name = &(@as([max_name_bytes + 1]u8, @splat('b'))), .arguments = valid, .offered = .full, .expected = .unknown_tool },
        // A tool the Session offered before and withdrew is removed, not
        // unknown; a provider-run one never runs as a call either way.
        .{ .name = "bash", .arguments = valid, .offered = .empty, .ever = .full, .expected = .unknown_tool, .described = true, .removed = true },
        .{ .name = "web_search", .arguments = "{}", .offered = .empty, .ever = .full, .expected = .unknown_tool },
    }) |case| {
        var name: Source = .{ .bytes = case.name };
        var arguments: TestSource = .{ .bytes = case.arguments };
        const offered = Offered.since(case.offered, case.ever);
        const facts = try inspectCall(&name, case.name.len, &arguments, &offered);
        try std.testing.expectEqual(case.expected, classifyCall(&facts));
        try std.testing.expectEqual(case.described, facts.bashArguments() != null);
        try std.testing.expectEqual(case.removed, facts.removed);
    }
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
    key: protocol.Bounded(16) = .{},
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
    stdin_utf8: protocol.Utf8State = .{},

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
                                if (!protocol.ToolPresentation.validDescription(self.result.description.slice())) return .{ .invalid = .description_invalid };
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

fn emit(destination: ?*protocol.Bounded(16), writer: anytype, bytes: []const u8) !void {
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

const TestSource = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn peek(self: *TestSource) !?u8 {
        return if (self.position == self.bytes.len) null else self.bytes[self.position];
    }

    pub fn take(self: *TestSource) !u8 {
        const byte = (try self.peek()) orelse return error.ShortCanonicalRead;
        self.position += 1;
        return byte;
    }
};

const TestWriter = struct {
    bytes: [128]u8 = undefined,
    length: usize = 0,

    fn writeAll(self: *TestWriter, bytes: []const u8) !void {
        if (self.length + bytes.len > self.bytes.len) return error.TestWriterFull;
        @memcpy(self.bytes[self.length..][0..bytes.len], bytes);
        self.length += bytes.len;
    }

    fn slice(self: *const TestWriter) []const u8 {
        return self.bytes[0..self.length];
    }
};

test "resumable Bash parser preserves state across every byte boundary" {
    var source = TestSource{
        .bytes = " \n{\"description\":\"Read \\u20ac\\ud83d\\ude00\",\"timeout_ms\":123,\"cmd\":\"a\\n\\u20ac\\ud83d\\ude00\\\\z\"}\t",
    };
    var writer: TestWriter = .{};
    var input: TestWriter = .{};
    var parser: BashParser = .{};
    while (true) switch (try parser.advance(&source, &writer, &input, 1)) {
        .pending => {},
        .invalid => return error.TestUnexpectedInvalidDescriptor,
        .complete => |arguments| {
            try std.testing.expectEqual(@as(?u64, 123), arguments.timeout_ms);
            try std.testing.expectEqualStrings("Read €😀", arguments.description.slice());
            try std.testing.expectEqualStrings("a\n€😀\\z", writer.slice());
            break;
        },
    };
}

test "resumable Bash parser rejects malformed split values" {
    const descriptors = [_][]const u8{
        "{\"description\":\"Run command\",\"cmd\":\"\\ud83dX\",\"timeout_ms\":null}",
        "{\"description\":\"Run command\",\"cmd\":\"ok\",\"timeout_ms\":9223372036854775808}",
        "{\"description\":\"Run command\",\"cmd\":\"ok\",\"timeout_ms\":null,\"cmd\":\"again\"}",
        "{\"description\":\"Run command\",\"cmd\":\"ok\",\"timeout_ms\":null,\"stdin\":null,\"stdin\":\"again\"}",
        "{\"description\":\"Run command\",\"cmd\":\"ok\",\"timeout_ms\":null,\"stdin\":42}",
    };
    for (descriptors) |descriptor| {
        var source = TestSource{ .bytes = descriptor };
        var writer: TestWriter = .{};
        var input: TestWriter = .{};
        var parser: BashParser = .{};
        while (true) switch (try parser.advance(&source, &writer, &input, 1)) {
            .pending => {},
            .invalid => break,
            .complete => return error.TestUnexpectedValidDescriptor,
        };
    }
}

test "Bash stdin stays distinct from command across every decoded byte" {
    const cases = [_]struct { field: []const u8, present: bool, expected: []const u8 }{
        .{ .field = "", .present = false, .expected = "" },
        .{ .field = ",\"stdin\":null", .present = false, .expected = "" },
        .{ .field = ",\"stdin\":\"\"", .present = true, .expected = "" },
        .{ .field = ",\"stdin\":\"`x` $(y) 'z' \\\"q\\\"\\n\\u0000\\u20ac\\ud83d\\ude00\"", .present = true, .expected = "`x` $(y) 'z' \"q\"\n\x00€😀" },
    };
    var buffer: [512]u8 = undefined;
    for (cases) |case| {
        var source: TestSource = .{ .bytes = try std.fmt.bufPrint(&buffer, "{{\"description\":\"Read input\",\"cmd\":\"cat\",\"timeout_ms\":null{s}}}", .{case.field}) };
        var command: TestWriter = .{};
        var input: TestWriter = .{};
        var parser: BashParser = .{};
        while (true) switch (try parser.advance(&source, &command, &input, 1)) {
            .pending => {},
            .invalid => return error.TestUnexpectedInvalidDescriptor,
            .complete => |arguments| {
                try std.testing.expectEqualStrings("cat", command.slice());
                try std.testing.expectEqual(case.present, arguments.stdin_present);
                try std.testing.expectEqualStrings(case.expected, input.slice());
                break;
            },
        };
    }
}

test "Bash stdin rejects invalid UTF-8 without coercion" {
    for ([_][]const u8{ "\xff", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe2\x82", "\x80", "\\ud800" }) |invalid| {
        var buffer: [256]u8 = undefined;
        var source = TestSource{ .bytes = try std.fmt.bufPrint(&buffer, "{{\"description\":\"Read input\",\"cmd\":\"cat\",\"stdin\":\"{s}\",\"timeout_ms\":null}}", .{invalid}) };
        try std.testing.expect(!try validBashArguments(&source));
    }
}

test "rejected Bash arguments name what is wrong" {
    const cases = [_]struct { []const u8, BashProblem }{
        .{ "", .malformed_json },
        .{ "{", .malformed_json },
        .{ "[]", .malformed_json },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\"} x", .malformed_json },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\",}", .malformed_json },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\",\"cwd\":\"/\"}", .unknown_field },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\",\"a_field_name_longer_than_sixteen\":1}", .unknown_field },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\",\"cmd\":\"false\"}", .duplicate_field },
        .{ "{\"description\":\"Run tests\"}", .missing_cmd },
        .{ "{\"cmd\":\"true\"}", .missing_description },
        .{ "{\"description\":\"Run tests\",\"cmd\":7}", .cmd_invalid },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"a\\u0000b\"}", .cmd_invalid },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"\\ud83d\\n\"}", .cmd_invalid },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"\\ud83d\\q\"}", .malformed_json },
        .{ "{\"description\":\"\",\"cmd\":\"true\"}", .description_invalid },
        .{ "{\"description\":\"" ++ @as([101]u8, @splat('a')) ++ "\",\"cmd\":\"true\"}", .description_invalid },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\",\"stdin\":42}", .stdin_invalid },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\",\"stdin\":\"\xff\"}", .stdin_invalid },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\",\"timeout_ms\":0}", .timeout_invalid },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\",\"timeout_ms\":1.5}", .timeout_invalid },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\",\"timeout_ms\":\"5\"}", .timeout_invalid },
        .{ "{\"description\":\"Run tests\",\"cmd\":\"true\",\"timeout_ms\":9223372036854775808}", .timeout_invalid },
    };
    for (cases) |case| {
        var source = TestSource{ .bytes = case[0] };
        const check = try checkBashArguments(&source);
        errdefer std.debug.print("arguments: {s}\n", .{case[0]});
        try std.testing.expectEqual(BashCheck{ .rejected = case[1] }, check);
    }
    // Optional fields may be omitted or null.
    for ([_][]const u8{
        "{\"description\":\"Run tests\",\"cmd\":\"true\"}",
        "{\"description\":\"Run tests\",\"cmd\":\"true\",\"stdin\":null,\"timeout_ms\":null}",
    }) |arguments| {
        var source = TestSource{ .bytes = arguments };
        try std.testing.expect(try checkBashArguments(&source) == .accepted);
    }
}

test "an invalid-arguments result tells the model what was wrong" {
    var buffer: [192]u8 = undefined;
    // The name is read only for an unknown tool.
    var name = struct {
        fn next(_: *@This()) !?u8 {
            return error.TestUnexpectedNameRead;
        }
    }{};
    const cases = [_]struct { BashProblem, []const u8 }{
        .{ .malformed_json, "Invalid arguments for tool 'bash': the arguments are not one well-formed JSON object." },
        .{ .unknown_field, "Invalid arguments for tool 'bash': only cmd, description, stdin and timeout_ms are accepted." },
        .{ .duplicate_field, "Invalid arguments for tool 'bash': a field appears more than once." },
        .{ .missing_cmd, "Invalid arguments for tool 'bash': cmd is required." },
        .{ .missing_description, "Invalid arguments for tool 'bash': description is required." },
        .{ .cmd_invalid, "Invalid arguments for tool 'bash': cmd must be a string of UTF-8 text with no NUL characters." },
        .{ .description_invalid, "Invalid arguments for tool 'bash': description must be a nonblank, single-line string of UTF-8 text, at most 100 bytes." },
        .{ .stdin_invalid, "Invalid arguments for tool 'bash': stdin must be a string of UTF-8 text." },
        .{ .timeout_invalid, "Invalid arguments for tool 'bash': timeout_ms must be an integer from 1 to 9223372036854775807." },
    };
    comptime std.debug.assert(cases.len == std.enums.values(BashProblem).len);
    for (cases) |case| {
        const facts: CallFacts = .{ .tool = bash_record, .bash = .{ .rejected = case[0] } };
        try std.testing.expectEqualStrings(case[1], try rejectionResult(.invalid_arguments, &facts, &name, 4, @splat(0), &buffer));
    }
}

test "Bash descriptions are required and bounded by decoded UTF-8 bytes" {
    var missing = TestSource{ .bytes = "{\"cmd\":\"true\",\"timeout_ms\":null}" };
    try std.testing.expect(!try validBashArguments(&missing));
    const invalid = [_][]const u8{
        "\"\"",        "\"   \"",     "null",      "1", "\"line\\nnext\"", "\"line\\rnext\"",
        "\"\\u2028\"", "\"\\ud800\"", "\"\xc3(\"",
    };
    var buffer: [512]u8 = undefined;
    for (invalid) |description| {
        var source = TestSource{ .bytes = try std.fmt.bufPrint(&buffer, "{{\"cmd\":\"true\",\"timeout_ms\":null,\"description\":{s}}}", .{description}) };
        try std.testing.expect(!try validBashArguments(&source));
    }
    for ([_][]const u8{ @as([98]u8, @splat('a')) ++ "é", &@as([50 * 6]u8, @bitCast(@as([50][6]u8, @splat("\\u00e9".*)))) }) |description| {
        var source = TestSource{ .bytes = try std.fmt.bufPrint(&buffer, "{{\"description\":\"{s}\",\"cmd\":\"printf ok\",\"timeout_ms\":null}}", .{description}) };
        try std.testing.expect(try validBashArguments(&source));
    }
    for ([_][]const u8{ @as([99]u8, @splat('a')) ++ "é", &@as([51 * 6]u8, @bitCast(@as([51][6]u8, @splat("\\u00e9".*)))) }) |description| {
        var source = TestSource{ .bytes = try std.fmt.bufPrint(&buffer, "{{\"cmd\":\"true\",\"description\":\"{s}\",\"timeout_ms\":null}}", .{description}) };
        try std.testing.expect(!try validBashArguments(&source));
    }
    var duplicate = TestSource{ .bytes = "{\"description\":\"Run tests\",\"cmd\":\"true\",\"description\":\"Read files\",\"timeout_ms\":null}" };
    try std.testing.expect(!try validBashArguments(&duplicate));
}

test "every provider-run tool the Host offers is run by some provider" {
    for (std.meta.tags(Tool)) |tool| {
        const offered = record(tool);
        if (offered.owner != .provider) continue;
        var run = false;
        for (std.enums.values(protocol.Provider)) |provider| run = run or provider.runsTool(offered.name);
        try std.testing.expect(run);
    }
}

test "MCP calls check only one JSON object and derive their runner" {
    const Source = struct {
        bytes: []const u8,
        position: usize = 0,
        fn next(self: *@This()) !?u8 {
            if (self.position == self.bytes.len) return null;
            defer self.position += 1;
            return self.bytes[self.position];
        }
    };
    const records = [_]Record{.{ .name = "fetch_page", .owner = .mcp, .server = "docs" }};
    var offered: Offered = .of(.initOne(.bash));
    var names: [1]protocol.Bounded(max_name_bytes) = .{.{ .len = 0 }};
    try names[0].set("fetch_page");
    offered.mcp_names = &names;
    offered.mcp_offered = &.{true};
    // Ownership, not a built-in spelling, chooses argument validation.
    var named_bash: [1]protocol.Bounded(max_name_bytes) = .{.{ .len = 0 }};
    try named_bash[0].set("bash");
    var shadowed = offered;
    shadowed.mcp_names = &named_bash;
    var bash_name: Source = .{ .bytes = "bash" };
    var empty_arguments: TestSource = .{ .bytes = "{}" };
    const owned = try inspectCall(&bash_name, 4, &empty_arguments, &shadowed);
    try std.testing.expectEqual(@as(?protocol.ProposalRejection, null), classifyCall(&owned));
    try std.testing.expect(owned.bash == null);
    try std.testing.expectEqual(Runner.mcp, owned.tool.?.runner());
    try std.testing.expectEqual(Runner.mcp, records[0].runner());
    try std.testing.expectEqual(Runner.bash, record(.bash).runner());
    const Case = struct { arguments: []const u8, valid: bool };
    for ([_]Case{
        .{ .arguments = "{}", .valid = true },
        .{ .arguments = " {\"anything\":[true,false,null,-1.2e+3,{},[]],\"text\":\"é\\uD83D\\uDE00\"} \n", .valid = true },
        .{ .arguments = "{\"rui_call_description\":42,\"duplicate\":1,\"duplicate\":2}", .valid = true },
        .{ .arguments = "", .valid = false },
        .{ .arguments = "{", .valid = false },
        .{ .arguments = "[]", .valid = false },
        .{ .arguments = "{}{}", .valid = false },
        .{ .arguments = "{\"x\":01}", .valid = false },
        .{ .arguments = "{\"x\":1,}", .valid = false },
        .{ .arguments = "{\"x\":\"\\uD800\"}", .valid = false },
        .{ .arguments = "{\"x\":\"\\uDC00\"}", .valid = false },
        .{ .arguments = "{\"x\":\"\xff\"}", .valid = false },
    }) |case| {
        var name: Source = .{ .bytes = "fetch_page" };
        var arguments: TestSource = .{ .bytes = case.arguments };
        const facts = try inspectCall(&name, name.bytes.len, &arguments, &offered);
        try std.testing.expectEqual(if (case.valid) @as(?protocol.ProposalRejection, null) else .invalid_arguments, classifyCall(&facts));
        if (!case.valid) {
            var buffer: [192]u8 = undefined;
            try std.testing.expectEqualStrings("Invalid arguments for tool 'fetch_page': the arguments are not one well-formed JSON object.", try rejectionResult(.invalid_arguments, &facts, &name, name.bytes.len, undefined, &buffer));
        }
    }
}

test "MCP argument validation preserves source read failures" {
    const Source = struct {
        fn next(_: *@This()) !?u8 {
            return null;
        }
        fn peek(_: *@This()) error{InjectedReadFailure}!?u8 {
            return error.InjectedReadFailure;
        }
        fn take(_: *@This()) error{InjectedReadFailure}!u8 {
            return error.InjectedReadFailure;
        }
    };
    var source: Source = .{};
    try std.testing.expectError(error.InjectedReadFailure, checkMcpArguments(&source));
}
