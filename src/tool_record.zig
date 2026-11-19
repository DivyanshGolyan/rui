const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const built_in_tool = @import("built_in_tool.zig");
const content_string = @import("content_string.zig");
const tool_name = @import("tool_name.zig");
const tool_presentation = @import("tool_presentation.zig");

pub const message_agent_max_text_bytes = 64 * 1024;

pub const message_agent_description = "Send a Message to another Rui Session by its ID. It returns once the Message is delivered, before any answer. A reply, if the receiver sends one, arrives later as a Message that starts your next turn.";
pub const message_agent_schema = "{\"type\":\"object\",\"properties\":{" ++
    "\"id\":{\"type\":\"string\",\"description\":\"The receiving Session's six-character ID.\"}," ++
    std.fmt.comptimePrint("\"text\":{{\"type\":\"string\",\"description\":\"The Message: nonempty UTF-8, at most {d} bytes.\"}}", .{message_agent_max_text_bytes}) ++
    "},\"required\":[\"id\",\"text\"],\"additionalProperties\":false}";

pub const find_tools_description = "Find and load tools available to this Session but not yet loaded. Give one to eight space-separated search words, at most 64 bytes each; a tool matches any word in its name or description, ignoring ASCII case. Loads at most eight matches in name order. Loaded tools become available on your next request.";
pub const find_tools_schema = "{\"type\":\"object\",\"properties\":{\"words\":{\"type\":\"string\",\"description\":\"One to eight search words separated by ASCII spaces; each word is at most 64 bytes.\"}},\"required\":[\"words\"],\"additionalProperties\":false}";

pub const read_action_description = "Read an Action in your own Session by its decimal action ID. Pending Actions report waiting_approval, queued or attempted. A resolved Action returns its immutable final Resolution and up to 4096 UTF-8 bytes, with byte offsets and a more flag. Continue with the returned next offset; reading never consumes or stops the Action. Published values are returned in pages; pass the returned values.next as after to continue. This is polling, not a subscription.";
pub const read_action_schema = "{\"type\":\"object\",\"properties\":{" ++
    "\"action\":{\"type\":\"string\",\"pattern\":\"^[1-9][0-9]*$\",\"maxLength\":19,\"description\":\"Action ID in your own Session; positive decimal, at most 9223372036854775807.\"}," ++
    std.fmt.comptimePrint("\"offset\":{{\"type\":\"string\",\"pattern\":\"^(0|[1-9][0-9]*)$\",\"maxLength\":10,\"description\":\"UTF-8 byte cursor, at most {d}; omitted means zero. Pending Actions require zero.\"}}", .{@import("content_string.zig").max_bytes}) ++
    ",\"after\":{\"type\":\"string\",\"pattern\":\"^(0|[1-9][0-9]*)$\",\"maxLength\":19,\"description\":\"Return values after this ordinal; omitted means zero.\"}" ++
    "},\"required\":[\"action\"],\"additionalProperties\":false}";

pub const stop_action_description = "Stop an Action in your own Session by its decimal Action ID. Returns its final Resolution once it has ended.";
pub const stop_action_schema = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"pattern\":\"^[1-9][0-9]*$\",\"maxLength\":19}},\"required\":[\"action\"],\"additionalProperties\":false}";

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

pub const start_agent_description = "Start another Rui agent on a task. It creates the agent's Session, gives it the task as its first Message and returns the agent's ID at once, before any answer. " ++
    "An attached agent is your child: it works in your Workspace with your provider and Bash environment, and stops when you are stopped or run out of context. A standalone agent has its own lifetime. " ++
    "The spec may only narrow your own tools and permission mode.";
pub const start_agent_schema = "{\"type\":\"object\",\"properties\":{" ++
    std.fmt.comptimePrint("\"task\":{{\"type\":\"string\",\"description\":\"The agent's first Message: nonempty UTF-8, at most {d} bytes.\"}},", .{message_agent_max_text_bytes}) ++
    "\"attached\":{\"type\":\"boolean\",\"description\":\"true starts your child, which stops with you; false starts a standalone agent.\"}," ++
    "\"preset\":{\"type\":\"string\",\"description\":\"A connect-time preset; spec fields override it.\"}," ++
    "\"spec\":{\"type\":\"object\",\"properties\":{" ++ agent_spec_properties ++
    "},\"additionalProperties\":false}" ++
    "},\"required\":[\"task\",\"attached\"],\"anyOf\":[{\"required\":[\"spec\"],\"properties\":{\"spec\":{\"required\":[" ++ agent_required_properties ++ "]}}},{\"required\":[\"preset\"]}],\"additionalProperties\":false}";

const agent_required_properties = blk: {
    var required: []const u8 = "";
    for (@import("session_settings.zig").entries) |entry| {
        if (entry.create == .must_value) required = required ++ (if (required.len == 0) "" else ",") ++ "\"" ++ entry.spec ++ "\"";
    }
    break :blk required;
};

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
    break :blk properties ++ ",\"preferences\":{\"type\":\"object\",\"properties\":{\"reasoning_effort\":{\"type\":\"string\",\"enum\":[\"none\",\"low\",\"medium\",\"high\",\"xhigh\",\"max\"]},\"permission_mode\":{\"type\":\"string\",\"enum\":[\"ask\",\"bypass\"]}},\"additionalProperties\":false}";
};

pub const skill_description = "Invoke an advertised skill by name to read its complete raw SKILL.md and absolute path. Reload rescans this Session's repository and Host-home .agents/skills roots, appending only changed catalog entries. Skills are ordinary conversation content, grant no tools or permissions, and execute nothing on load.";
pub const skill_schema = "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"enum\":[\"invoke\",\"reload\"]},\"name\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":64}},\"required\":[\"operation\"],\"additionalProperties\":false}";

/// Bash receives the command as one `-c` argument. Linux rejects an
/// argument of 128 KiB including its NUL (MAX_ARG_STRLEN with 4 KiB pages),
/// and with a small stack rlimit the whole argv+environment shares a 128 KiB
/// floor; 8 KiB stays for the shell path, environment and pointers.
pub const bash_max_command_bytes: usize = 120 * 1024;
pub const bash_max_stdin_bytes: usize = bash_max_command_bytes;

pub const Owner = enum { rui, provider, mcp };

pub const max_server_bytes = tool_name.max_bytes;

pub const Record = struct {
    name: []const u8,
    description: []const u8 = "",
    input_schema: []const u8 = "",
    owner: Owner,
    server: []const u8 = "",
    read_only: bool = false,

    pub fn runner(self: *const Record) Runner {
        return Runner.of(self);
    }
};

pub const max_name_bytes = tool_name.max_bytes;

pub const max_tools = tool_name.max_tools;

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
        if (self.read_only) hashField(&hash, "read_only");
        return hash.finalResult();
    }
};

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

pub const HostToolSet = struct {
    records: []const Record,
    digests: []const [32]u8,

    configured_servers: []const []const u8 = &.{},

    pub const Resolution = union(enum) { found: usize, unknown_tool, mcp_server_unavailable };
    pub const max_refusal_message_bytes = 768;

    pub const MissingTool = struct {
        name: Bounded(tool_name.max_bytes),
        host_tool_set: *const HostToolSet,

        pub fn write(self: *const MissingTool, out: *std.Io.Writer) !void {
            try self.host_tool_set.writeMissingTool(self.name.slice(), out);
        }
    };

    pub fn missingTool(self: *const HostToolSet, name: []const u8) MissingTool {
        var detail: MissingTool = .{ .name = .{ .len = 0 }, .host_tool_set = self };
        detail.name.set(name) catch unreachable;
        return detail;
    }

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

pub fn validServer(each: *const Record) bool {
    return if (each.owner == .mcp) tool_name.valid(each.server) else each.server.len == 0 and !each.read_only;
}

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

pub const read_action_record: Record = .{
    .name = "read_action",
    .owner = .rui,
    .description = read_action_description,
    .input_schema = read_action_schema,
};

pub const stop_action_record: Record = .{
    .name = "stop_action",
    .owner = .rui,
    .description = stop_action_description,
    .input_schema = stop_action_schema,
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

pub const read_image_record: Record = .{
    .name = "read_image",
    .owner = .rui,
    .description = "Read a PNG or JPEG image from a regular file on the Host. Relative paths resolve in the Session Workspace; absolute paths may name other Host-local files. Returns a saved image observation. URLs and special files are not supported.",
    .input_schema = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":4096}},\"required\":[\"path\"],\"additionalProperties\":false}",
};

/// Largest result excerpt allowance used by any supported runner.
pub const max_result_excerpt_bytes: u32 = 20_000;

pub const Profile = struct { excerpt_bytes: u32, retain: bool };

pub const Runner = enum {
    bash,
    read_image,
    core,
    mcp,
    provider,

    /// The offer comes from the frozen tool set of the model operation.
    pub fn resultProfile(self: Runner, bash_offered: bool) Profile {
        return switch (self) {
            .bash => .{ .excerpt_bytes = max_result_excerpt_bytes, .retain = true },
            .mcp => .{ .excerpt_bytes = 10_000, .retain = bash_offered },
            .read_image => .{ .excerpt_bytes = 0, .retain = false },
            .core => .{ .excerpt_bytes = 0, .retain = false }, // Core pagers own their already-shaped windows.
            .provider => unreachable,
        };
    }

    pub fn beforeAdmissionStopText(self: Runner) []const u8 {
        return switch (self) {
            .bash => @import("bash_action_text.zig").stopped_before_admission,
            .read_image => @import("action_text.zig").stopped_before_admission,
            .mcp => @import("mcp/action_text.zig").stopped_before_admission,
            .core => @import("action_text.zig").stopped_before_admission,
            .provider => unreachable,
        };
    }

    pub fn stoppedText(self: Runner, _: anytype, result: []const u8) []const u8 {
        return switch (self) {
            .bash => @import("bash_action_text.zig").stopped_before_admission,
            .read_image => "Stopped before this image read completed.",
            .mcp => result,
            .core, .provider => unreachable,
        };
    }

    pub fn indeterminateText(self: Runner) []const u8 {
        return switch (self) {
            .bash => @import("bash_action_text.zig").indeterminate,
            .read_image => "The Host stopped before saving this image read result. The read may have completed; it was not automatically repeated.",
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

pub const BuiltInRow = struct { record: *const Record, runner: Runner };
pub const built_in_rows = std.enums.EnumArray(Tool, BuiltInRow).init(.{
    .bash = .{ .record = &bash_record, .runner = .bash },
    .find_tools = .{ .record = &find_tools_record, .runner = .core },
    .message_agent = .{ .record = &message_agent_record, .runner = .core },
    .read_action = .{ .record = &read_action_record, .runner = .core },
    .read_image = .{ .record = &read_image_record, .runner = .read_image },
    .read_transcript = .{ .record = &read_transcript_record, .runner = .core },
    .skill = .{ .record = &skill_record, .runner = .core },
    .start_agent = .{ .record = &start_agent_record, .runner = .core },
    .stop_action = .{ .record = &stop_action_record, .runner = .core },
    .web_search = .{ .record = &web_search_record, .runner = .provider },
});

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

pub fn record(tool: Tool) *const Record {
    return built_in_rows.get(tool).record;
}

pub const built_in_tool_set: HostToolSet = .{ .records = &built_in_records, .digests = &built_in_digests };

const built_in_records = blk: {
    var out: [std.enums.values(Tool).len]Record = undefined;
    for (std.enums.values(Tool), &out) |tool, *each| each.* = record(tool).*;
    break :blk out;
};

const built_in_digests = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [built_in_records.len][32]u8 = undefined;
    selectDigests(&built_in_records, &@import("tool_digests_generated.zig").entries, &out);
    break :blk out;
};

/// Select a matching snapshot for each record, computing the digest when one is absent or stale.
pub fn selectDigests(records: []const Record, snapshots: anytype, out: [][32]u8) void {
    std.debug.assert(records.len == out.len);
    for (records, out, 0..) |*each, *digest, index| {
        if (index < snapshots.len and sameRecord(each, &snapshots[index].record)) {
            digest.* = snapshots[index].digest;
        } else {
            digest.* = recordDigest(each);
        }
    }
}

// A snapshot serves only the exact record it was generated from. A changed record is hashed
// normally, so an out-of-date snapshot cannot change a tool's persistent identity.
fn sameRecord(a: *const Record, b: anytype) bool {
    return std.mem.eql(u8, @tagName(a.owner), @tagName(b.owner)) and a.read_only == b.read_only and
        std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.server, b.server) and
        std.mem.eql(u8, a.description, b.description) and std.mem.eql(u8, a.input_schema, b.input_schema);
}

comptime {
    for (std.enums.values(Tool)) |tool| {
        const r = record(tool);
        if (built_in_rows.get(tool).runner == .mcp) @compileError("built-in MCP runner");
        if (!std.mem.eql(u8, r.name, @tagName(tool)) or r.name.len > max_name_bytes) @compileError("tool record name");
    }
}

pub const Offered = struct {
    names: []const u8 = "",
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

test "EXR-65 tool identities survive matching, stale and missing digest snapshots" {
    const Snapshot = @import("tool_digests_generated.zig").Entry;
    const base: Record = .{ .name = "fetch_page", .owner = .mcp, .server = "docs", .description = "Fetch a page.", .input_schema = "{\"type\":\"object\"}" };
    const expected = recordDigest(&base);
    const snapshot: Snapshot = .{ .record = .{ .name = base.name, .owner = .mcp, .server = base.server, .description = base.description, .input_schema = base.input_schema, .read_only = base.read_only }, .digest = expected };
    const snapshots = [_]Snapshot{snapshot};
    var selected: [2][32]u8 = undefined;
    selectDigests(&.{base}, &snapshots, selected[0..1]);
    try std.testing.expectEqualSlices(u8, &recordDigest(&base), &selected[0]);

    var changes: [5]Record = .{ base, base, base, base, base };
    changes[0].name = "fetch_other";
    changes[1].description = "Fetch another page.";
    changes[2].input_schema = "{}";
    changes[3].server = "other";
    changes[4].read_only = true;
    for (changes) |changed| {
        selectDigests(&.{changed}, &snapshots, selected[0..1]);
        try std.testing.expectEqualSlices(u8, &recordDigest(&changed), &selected[0]);
    }
    var owner_base = base;
    owner_base.owner = .rui;
    owner_base.server = "";
    var owner_snapshot = snapshot;
    owner_snapshot.record.owner = .rui;
    owner_snapshot.record.server = "";
    owner_snapshot.digest = recordDigest(&owner_base);
    var owner_changed = owner_base;
    owner_changed.owner = .provider;
    const owner_snapshots = [_]Snapshot{owner_snapshot};
    selectDigests(&.{owner_changed}, &owner_snapshots, selected[0..1]);
    try std.testing.expectEqualSlices(u8, &recordDigest(&owner_changed), &selected[0]);
    selectDigests(&.{base}, &@as([0]Snapshot, .{}), selected[0..1]);
    try std.testing.expectEqualSlices(u8, &recordDigest(&base), &selected[0]);
    selectDigests(&.{ base, changes[0] }, &snapshots, &selected);
    try std.testing.expectEqualSlices(u8, &recordDigest(&base), &selected[0]);
    try std.testing.expectEqualSlices(u8, &recordDigest(&changes[0]), &selected[1]);

    try std.testing.expect(built_in_tool_set.valid());
    for (std.enums.values(Tool), 0..) |tool, index| try std.testing.expectEqual(@as(?usize, index), built_in_tool_set.find(@tagName(tool)));
    try std.testing.expectEqual(@as(?usize, null), built_in_tool_set.find("bas"));
    try std.testing.expectEqual(@as(?usize, null), built_in_tool_set.find("edit"));
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

test "start_agent schema requires a model unless a preset supplies one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), start_agent_schema, .{});
    const alternatives = schema.object.get("anyOf").?.array.items;
    const direct = alternatives[0].object;
    const required = direct.get("properties").?.object.get("spec").?.object.get("required").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), required.len);
    try std.testing.expectEqualStrings("model", required[0].string);
    const preset = alternatives[1].object.get("required").?.array.items;
    try std.testing.expectEqualStrings("preset", preset[0].string);
}

test "result profiles follow runner and frozen Bash offer" {
    for ([_]bool{ false, true }) |offer| {
        try std.testing.expectEqualDeep(Profile{ .excerpt_bytes = 20_000, .retain = true }, Runner.bash.resultProfile(offer));
        try std.testing.expectEqualDeep(Profile{ .excerpt_bytes = 10_000, .retain = offer }, Runner.mcp.resultProfile(offer));
        try std.testing.expectEqualDeep(Profile{ .excerpt_bytes = 0, .retain = false }, Runner.read_image.resultProfile(offer));
        try std.testing.expectEqualDeep(Profile{ .excerpt_bytes = 0, .retain = false }, Runner.core.resultProfile(offer));
    }
}

test "all result profiles fit the shared excerpt maximum" {
    inline for (std.meta.tags(Runner)) |runner| {
        switch (runner) {
            .provider => {}, // Provider calls do not use the Result route.
            .bash, .mcp, .read_image, .core => {
                for ([_]bool{ false, true }) |offer| {
                    try std.testing.expect(runner.resultProfile(offer).excerpt_bytes <= max_result_excerpt_bytes);
                }
            },
        }
    }
}
