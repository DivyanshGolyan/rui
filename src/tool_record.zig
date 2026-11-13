//! Persisted tool records, their identities and built-in tool set.
const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const built_in_tool = @import("built_in_tool.zig");
const content_string = @import("content_string.zig");
const tool_name = @import("tool_name.zig");
const tool_presentation = @import("tool_presentation.zig");

/// The most decoded bytes a `message_agent` text carries.
pub const message_agent_max_text_bytes = 64 * 1024;

// Prompt text: written here, and given no tests (D141).
pub const message_agent_description = "Send a Message to another Rui Session by its ID. It returns once the Message is delivered, before any answer. A reply, if the receiver sends one, arrives later as a Message that starts your next turn.";
pub const message_agent_schema = "{\"type\":\"object\",\"properties\":{" ++
    "\"id\":{\"type\":\"string\",\"description\":\"The receiving Session's six-character ID.\"}," ++
    std.fmt.comptimePrint("\"text\":{{\"type\":\"string\",\"description\":\"The Message: nonempty UTF-8, at most {d} bytes.\"}}", .{message_agent_max_text_bytes}) ++
    "},\"required\":[\"id\",\"text\"],\"additionalProperties\":false}";

// Prompt text: written here, and given no tests (D141).
pub const find_tools_description = "Find and load tools available to this Session but not yet loaded. Give one to eight space-separated search words, at most 64 bytes each; a tool matches any word in its name or description, ignoring ASCII case. Loads at most eight matches in name order. Loaded tools become available on your next request.";
pub const find_tools_schema = "{\"type\":\"object\",\"properties\":{\"words\":{\"type\":\"string\",\"description\":\"One to eight search words separated by ASCII spaces; each word is at most 64 bytes.\"}},\"required\":[\"words\"],\"additionalProperties\":false}";

// Prompt text: written here, and given no tests (D141).
pub const read_transcript_description = "Read any Rui Session's public transcript, newest first. Omit id to read your own. Outline lines give entry addresses, kinds, people or tools, call notes, result codes, byte sizes and quoted first-line previews (at most 100 bytes). Use before to page older entries. Open an entry with full and continue its 16 KiB text windows with offset; call entries show the tool name and arguments JSON. Use query for ASCII-case-insensitive word search with quoted snippets; query cannot be combined with full. Private content is never shown.";
const transcript_kind_schema = blk: {
    var names: []const u8 = "";
    for (std.enums.values(@import("activity_read.zig").Kind), 0..) |kind, index| {
        names = names ++ (if (index == 0) "" else ",") ++ "\"" ++ @tagName(kind) ++ "\"";
    }
    break :blk "{\"type\":\"string\",\"enum\":[" ++ names ++ "]}";
};
pub const read_transcript_schema = "{\"type\":\"object\",\"properties\":{" ++
    "\"id\":{\"type\":\"string\",\"description\":\"Session ID; omitted means your own Session.\"}," ++
    "\"query\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":256,\"description\":\"Search public text (1 to 256 UTF-8 bytes); not with full.\"}," ++
    "\"kinds\":{\"type\":\"array\",\"items\":" ++ transcript_kind_schema ++ ",\"minItems\":1,\"description\":\"Public feed kind names, exactly as on the wire. Omitted means all kinds.\"}," ++
    "\"before\":{\"type\":\"string\",\"description\":\"List entries strictly older than this P or P.O address.\"}," ++
    "\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":16}," ++
    "\"full\":{\"type\":\"string\",\"description\":\"Open entry P.O instead of listing; omit kinds, before and limit.\"}," ++
    "\"offset\":{\"type\":\"integer\",\"minimum\":0,\"description\":\"Byte offset, only with full.\"}" ++
    "},\"additionalProperties\":false}";

// Prompt text: written here, and given no tests (D141).
pub const start_agent_description = "Start another Rui agent on a task. It creates the agent's Session, gives it the task as its first Message and returns the agent's ID at once, before any answer. " ++
    "An attached agent is your child: it works in your Workspace with your provider and Bash environment, and stops when you are stopped or run out of context. A standalone agent has its own lifetime. " ++
    "The spec may only narrow your own tools and permission mode.";
pub const start_agent_schema = "{\"type\":\"object\",\"properties\":{" ++
    std.fmt.comptimePrint("\"task\":{{\"type\":\"string\",\"description\":\"The agent's first Message: nonempty UTF-8, at most {d} bytes.\"}},", .{message_agent_max_text_bytes}) ++
    "\"attached\":{\"type\":\"boolean\",\"description\":\"true starts your child, which stops with you; false starts a standalone agent.\"}," ++
    "\"preset\":{\"type\":\"string\",\"description\":\"A connect-time preset; spec fields override it.\"}," ++
    "\"spec\":{\"type\":\"object\",\"properties\":{" ++ agent_spec_properties ++
    "},\"additionalProperties\":false}" ++
    "},\"required\":[\"task\",\"attached\"],\"anyOf\":[{\"required\":[\"spec\"]},{\"required\":[\"preset\"]}],\"additionalProperties\":false}";

// The same setting vocabulary and scalar kinds as the native wire. A child
// inherits provider and Workspace, so those alone are not spec properties.
const agent_spec_properties = blk: {
    var properties: []const u8 = "";
    for (@import("session_settings.zig").entries) |entry| {
        if (std.mem.eql(u8, entry.field, "workspace") or std.mem.eql(u8, entry.field, "provider")) continue;
        const kind = switch (entry.kind) {
            .tools => "array",
            .decimal_policy => "integer",
            .content => if (entry.json_object) "object" else "string",
            else => "string",
        };
        const json_type = if (entry.nullable) "[\"" ++ kind ++ "\",\"null\"]" else "\"" ++ kind ++ "\"";
        const extra = switch (entry.kind) {
            .tools => ",\"items\":{\"type\":\"string\"},\"uniqueItems\":true",
            else => if (std.mem.eql(u8, entry.field, "reasoning_effort"))
                ",\"enum\":[null,\"none\",\"low\",\"medium\",\"high\",\"xhigh\",\"max\"]"
            else if (std.mem.eql(u8, entry.field, "permission_mode"))
                ",\"enum\":[\"ask\",\"bypass\"]"
            else if (std.mem.eql(u8, entry.field, "output_schema"))
                ",\"description\":\"Optional JSON output schema object; null clears it.\""
            else
                "",
        };
        properties = properties ++ (if (properties.len == 0) "" else ",") ++ "\"" ++ entry.spec ++ "\":{\"type\":" ++ json_type ++ extra ++ "}";
    }
    break :blk properties;
};

pub const skill_description = "Invoke an advertised skill by name to read its complete raw SKILL.md and absolute path. Reload rescans this Session's repository and Host-home .agents/skills roots, appending only changed catalog entries. Skills are ordinary conversation content, grant no tools or permissions, and execute nothing on load.";
pub const skill_schema = "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"enum\":[\"invoke\",\"reload\"]},\"name\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":64}},\"required\":[\"operation\"],\"additionalProperties\":false}";

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
pub const max_server_bytes = tool_name.max_bytes;

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
    /// MCP ordering hint only; it never authorizes or retries a call.
    read_only: bool = false,

    pub fn runner(self: *const Record) Runner {
        return Runner.of(self);
    }
};

/// The longest function name a provider accepts (OpenAI: 64 characters);
/// a longer call name cannot match any record.
pub const max_name_bytes = tool_name.max_bytes;

/// The most tools one set offers.
pub const max_tools = tool_name.max_tools;

/// A record's identity: its name, owner, server and the content digests
/// of its description and input schema. A tool that moves to another
/// server or changes its read-only hint is another record.
pub fn recordDigest(member: *const Record) [32]u8 {
    return (RecordIdentity{
        .name = member.name,
        .owner = member.owner,
        .server = member.server,
        .read_only = member.read_only,
        .description = content_string.digest(member.description),
        .input_schema = content_string.digest(member.input_schema),
    }).digest();
}

/// A record's identity without its texts: a saved record already holds
/// their digests, so selecting it never reads or copies those texts.
pub const RecordIdentity = struct {
    name: []const u8,
    owner: Owner,
    server: []const u8,
    read_only: bool = false,
    description: [32]u8,
    input_schema: [32]u8,

    pub fn digest(self: *const RecordIdentity) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/tool-record/v1");
        hashField(&hash, self.name);
        hashField(&hash, @tagName(self.owner));
        hashField(&hash, self.server);
        hash.update(&self.description);
        hash.update(&self.input_schema);
        // Absent/false keeps every pre-hint record and saved set byte-identical.
        if (self.read_only) hashField(&hash, "read_only");
        return hash.finalResult();
    }
};

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
pub const HostToolSet = struct {
    records: []const Record,
    /// Each record's `recordDigest`, in the same order.
    digests: []const [32]u8,

    /// Launch-only names, borrowed until Host shutdown. Never part of a saved
    /// tool set or its digest: an empty server has no record to persist.
    configured_servers: []const []const u8 = &.{},

    pub const Resolution = union(enum) { found: usize, unknown_tool, mcp_server_unavailable };
    pub const max_refusal_message_bytes = 768;

    /// The name is owned; the Host tool set is borrowed until shutdown.
    /// Keep reply values small instead of copying formatted text along the
    /// engine's transaction/queue chain.
    pub const MissingTool = struct {
        name: Bounded(tool_name.max_bytes),
        host_tool_set: *const HostToolSet,

        pub fn write(self: *const MissingTool, out: *std.Io.Writer) !void {
            try self.host_tool_set.writeMissingTool(self.name.slice(), out);
        }
    };

    pub fn missingTool(self: *const HostToolSet, name: []const u8) MissingTool {
        var detail: MissingTool = .{ .name = .{ .len = 0 }, .host_tool_set = self };
        detail.name.set(name) catch unreachable; // ingress already checked the name
        return detail;
    }

    /// Raw MCP names carry no ownership hint. A missing name may belong to
    /// any configured server with no records, including no saved copies.
    pub fn resolve(self: *const HostToolSet, name: []const u8) Resolution {
        if (self.find(name)) |index| return .{ .found = index };
        var empty = self.emptyServers();
        if (empty.next() != null) return .mcp_server_unavailable;
        return .unknown_tool;
    }

    pub const EmptyServers = struct {
        host_tool_set: *const HostToolSet,
        at: usize = 0,

        pub fn next(self: *EmptyServers) ?[]const u8 {
            while (self.at < self.host_tool_set.configured_servers.len) {
                const name = self.host_tool_set.configured_servers[self.at];
                self.at += 1;
                for (self.host_tool_set.records) |entry| {
                    if (entry.owner == .mcp and std.mem.eql(u8, entry.server, name)) break;
                } else return name;
            }
            return null;
        }
    };

    pub fn emptyServers(self: *const HostToolSet) EmptyServers {
        return .{ .host_tool_set = self };
    }

    /// Advisory detail about this Host, not a claim of name ownership. The
    /// settings owner bounds this to eight server names of at most 64 bytes.
    pub fn writeMissingTool(self: *const HostToolSet, name: []const u8, out: *std.Io.Writer) !void {
        try out.print("spec.tools: {s} is not a known tool", .{name});
        var empty = self.emptyServers();
        const first = empty.next() orelse return;
        if (empty.next()) |second| {
            try out.print("; MCP servers {s}, {s}", .{ first, second });
            while (empty.next()) |server| try out.print(", {s}", .{server});
            try out.writeAll(" are unavailable and may provide it");
        } else try out.print("; MCP server {s} is unavailable and may provide it", .{first});
    }

    /// The index of the record named `name`.
    pub fn find(self: *const HostToolSet, name: []const u8) ?usize {
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
    pub fn valid(self: *const HostToolSet) bool {
        if (self.records.len != self.digests.len or self.records.len > max_host_tool_records) return false;
        for (self.records, self.digests, 0..) |*each, digest, index| {
            if (!tool_name.valid(each.name) or !validServer(each)) return false;
            if (index != 0 and std.mem.order(u8, self.records[index - 1].name, each.name) != .lt) return false;
            if (!std.mem.eql(u8, &digest, &recordDigest(each))) return false;
        }
        return true;
    }
};

/// An MCP record names its server, in the tool-name grammar; any other
/// record names none.
pub fn validServer(each: *const Record) bool {
    return if (each.owner == .mcp) tool_name.valid(each.server) else each.server.len == 0 and !each.read_only;
}

/// The most records a Host tool set holds; its saved set holds as many.
pub const max_host_tool_records = 1024;

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

pub const find_tools_record: Record = .{
    .name = "find_tools",
    .owner = .rui,
    .description = find_tools_description,
    .input_schema = find_tools_schema,
};

pub const message_agent_record: Record = .{
    .name = "message_agent",
    .owner = .rui,
    .description = message_agent_description,
    .input_schema = message_agent_schema,
};

pub const read_transcript_record: Record = .{
    .name = "read_transcript",
    .owner = .rui,
    .description = read_transcript_description,
    .input_schema = read_transcript_schema,
};

pub const skill_record: Record = .{
    .name = "skill",
    .owner = .rui,
    .description = skill_description,
    .input_schema = skill_schema,
};

pub const start_agent_record: Record = .{
    .name = "start_agent",
    .owner = .rui,
    .description = start_agent_description,
    .input_schema = start_agent_schema,
};

pub const web_search_record: Record = .{ .name = "web_search", .owner = .provider };

/// Who carries out an accepted call, derived from its frozen record and
/// never stored (D46). The two Action adapters run Rui-run Actions; core
/// tools run core commands (D24), and provider tools remain provider-owned.
pub const Runner = enum {
    bash,
    core,
    mcp,
    provider,

    pub fn beforeAdmissionStopText(self: Runner) []const u8 {
        return switch (self) {
            .bash => @import("bash_action_text.zig").stopped_before_admission,
            .mcp => @import("mcp/action_text.zig").stopped_before_admission,
            .core => @import("action_text.zig").stopped_before_admission,
            .provider => unreachable,
        };
    }

    /// Adapter-owned wording, not Store policy or persisted runner state.
    pub fn stoppedText(self: Runner, _: anytype, result: []const u8) []const u8 {
        return switch (self) {
            .bash => @import("bash_action_text.zig").stopped,
            .mcp => result,
            .core, .provider => unreachable,
        };
    }

    pub fn indeterminateText(self: Runner) []const u8 {
        return switch (self) {
            .bash => @import("bash_action_text.zig").indeterminate,
            .mcp => @import("mcp/action_text.zig").indeterminate,
            .core, .provider => unreachable,
        };
    }

    pub fn of(tool: *const Record) Runner {
        if (tool.owner == .mcp) return .mcp;
        if (tool.owner == .provider) return .provider;
        for (built_in_rows.values) |row| {
            if (std.mem.eql(u8, tool.name, row.record.name)) return row.runner;
        }
        return .bash;
    }
};

/// One row per BuiltInTool, in its name order. This is the authority for
/// each built-in's record and runner; EnumArray requires every tag once.
pub const BuiltInRow = struct { record: *const Record, runner: Runner };
pub const built_in_rows = std.enums.EnumArray(Tool, BuiltInRow).init(.{
    .bash = .{ .record = &bash_record, .runner = .bash },
    .find_tools = .{ .record = &find_tools_record, .runner = .core },
    .message_agent = .{ .record = &message_agent_record, .runner = .core },
    .read_transcript = .{ .record = &read_transcript_record, .runner = .core },
    .skill = .{ .record = &skill_record, .runner = .core },
    .start_agent = .{ .record = &start_agent_record, .runner = .core },
    .web_search = .{ .record = &web_search_record, .runner = .provider },
});

/// Core tools in table order. The Host's exhaustive dispatch switch over
/// this generated enum requires a runner arm for every core row.
pub const CoreTool = blk: {
    var names: []const []const u8 = &.{};
    for (built_in_rows.values) |row| {
        if (row.runner == .core) names = names ++ .{row.record.name};
    }
    var values: [names.len]u8 = undefined;
    for (&values, 0..) |*value, i| value.* = @intCast(i);
    break :blk @Enum(u8, .exhaustive, names, &values);
};

pub fn coreTool(name: []const u8) ?CoreTool {
    return std.meta.stringToEnum(CoreTool, name);
}

/// The built-in record of each tool `Tool` names: the text a new set saves.
pub fn record(tool: Tool) *const Record {
    return built_in_rows.get(tool).record;
}

/// The built-ins, as the tool set of a Host with no other tools.
pub const built_in_tool_set: HostToolSet = .{ .records = &built_in_records, .digests = &built_in_digests };

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

test "the built-in tool set is valid and finds each built-in by name" {
    try std.testing.expect(built_in_tool_set.valid());
    for (std.enums.values(Tool), 0..) |tool, index| try std.testing.expectEqual(@as(?usize, index), built_in_tool_set.find(@tagName(tool)));
    try std.testing.expectEqual(@as(?usize, null), built_in_tool_set.find("bas"));
    try std.testing.expectEqual(@as(?usize, null), built_in_tool_set.find("edit"));
}

comptime {
    for (std.enums.values(Tool)) |tool| {
        const r = record(tool);
        if (built_in_rows.get(tool).runner == .mcp) @compileError("built-in MCP runner");
        if (!std.mem.eql(u8, r.name, @tagName(tool)) or r.name.len > max_name_bytes) @compileError("tool record name");
    }
}

/// The saved member names the request offers, for every owner.
pub const Offered = struct {
    /// Borrowed comma-separated names from the request's saved tool set.
    names: []const u8 = "",
    /// Borrowed name identities and flags for otherwise unknown names that
    /// an earlier revision offered. Reusing the batch's content identities
    /// avoids retaining another copy of every call name.
    historical_digests: []const [32]u8 = &.{},
    withdrawn: []const bool = &.{},

    pub fn find(self: *const Offered, name: []const u8) ?[]const u8 {
        var names = std.mem.splitScalar(u8, self.names, ',');
        while (names.next()) |candidate| if (candidate.len != 0 and std.mem.eql(u8, candidate, name)) return candidate;
        return null;
    }

    pub fn wasWithdrawn(self: *const Offered, name: []const u8) bool {
        const digest = content_string.digest(name);
        for (self.historical_digests, self.withdrawn) |*candidate, withdrawn| {
            if (withdrawn and std.mem.eql(u8, candidate, &digest)) return true;
        }
        return false;
    }
};

/// The built-in tools; the wire owns their names.
pub const Tool = built_in_tool.BuiltInTool;
pub fn builtIn(name: []const u8) ?Tool {
    return std.meta.stringToEnum(Tool, name);
}

pub const ToolSet = built_in_tool.Selection;

pub const Description = Bounded(tool_presentation.max_description_bytes);

test "every built-in runner matches its table row" {
    for (std.enums.values(Tool)) |tool| {
        const row = built_in_rows.get(tool);
        try std.testing.expectEqual(row.runner, Runner.of(record(tool)));
        try std.testing.expectEqual(row.runner == .core, coreTool(row.record.name) != null);
    }
}

test "tool record read-only identity preserves existing digests" {
    // Pinned from the pre-hint v1 recipe, including content's domain prefix.
    const provider = recordDigest(&web_search_record);
    try std.testing.expectEqualStrings("effe976e5ce171d6033b8cfefd755255535a6bbb32c075577842ac0358417fa0", &std.fmt.bytesToHex(provider, .lower));
    const before: Record = .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page.", .input_schema = "{\"type\":\"object\"}" };
    const old = recordDigest(&before);
    try std.testing.expectEqualStrings("d7da1c4de845e471addfa3cc2335b2c3204d24499001d6cdc5e7f94b6169d822", &std.fmt.bytesToHex(old, .lower));
    var read = before;
    read.read_only = true;
    try std.testing.expect(validServer(&read));
    try std.testing.expect(!std.mem.eql(u8, &old, &recordDigest(&read)));
    const identity: RecordIdentity = .{ .name = read.name, .owner = read.owner, .server = read.server, .read_only = true, .description = content_string.digest(read.description), .input_schema = content_string.digest(read.input_schema) };
    try std.testing.expectEqualSlices(u8, &recordDigest(&read), &identity.digest());
    inline for (.{ Owner.rui, Owner.provider }) |owner| {
        const invalid: Record = .{ .name = "invalid", .owner = owner, .read_only = true };
        try std.testing.expect(!validServer(&invalid));
    }
}

test "MCP missing tools tool set resolution covers every empty-server combination" {
    const servers = [_][]const u8{ "notes", "other" };
    for (0..4) |mask| {
        var entries: [2]Record = undefined;
        var hashes: [2][32]u8 = undefined;
        var count: usize = 0;
        for (servers, 0..) |server, index| {
            if (mask & (@as(usize, 1) << @intCast(index)) == 0) continue;
            entries[count] = .{ .name = server, .owner = .mcp, .server = server, .input_schema = "{}" };
            hashes[count] = recordDigest(&entries[count]);
            count += 1;
        }
        const host_tool_set: HostToolSet = .{ .records = entries[0..count], .digests = hashes[0..count], .configured_servers = &servers };
        try std.testing.expect(host_tool_set.valid());
        try std.testing.expectEqualStrings(if (mask == 3) "unknown_tool" else "mcp_server_unavailable", @tagName(host_tool_set.resolve("lookup")));
        for (entries[0..count], 0..) |entry, index| try std.testing.expectEqual(index, host_tool_set.resolve(entry.name).found);
        var empty = host_tool_set.emptyServers();
        for (servers, 0..) |server, index| {
            if (mask & (@as(usize, 1) << @intCast(index)) == 0) try std.testing.expectEqualStrings(server, empty.next().?);
        }
        try std.testing.expectEqual(@as(?[]const u8, null), empty.next());
    }
}
