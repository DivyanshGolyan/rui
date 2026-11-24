const std = @import("std");
const Bounded = @import("bounded.zig").Bounded;
const built_in_tool = @import("built_in_tool.zig");
const content_string = @import("content_string.zig");
const tool_name = @import("tool_name.zig");
const tool_presentation = @import("tool_presentation.zig");

pub const message_agent_max_text_bytes = 64 * 1024;

pub const message_agent_description = "Send a Message to another Rui Session by its ID; the receiver sees your ID. It returns once the Message is delivered, before any answer. The receiver replies only if asked; a reply arrives later as a Message that starts your next turn, so end your turn instead of waiting.";
pub const message_agent_schema = "{\"type\":\"object\",\"properties\":{" ++
    "\"id\":{\"type\":\"string\",\"description\":\"The receiving Session's six-character ID.\"}," ++
    std.fmt.comptimePrint("\"text\":{{\"type\":\"string\",\"description\":\"The Message: nonempty UTF-8, at most {d} bytes.\"}}", .{message_agent_max_text_bytes}) ++
    "},\"required\":[\"id\",\"text\"],\"additionalProperties\":false}";

pub const find_tools_description = "Find and load tools available to this Session but not yet loaded, or ask every MCP server to list its tools again. Give one to eight space-separated search words, at most 64 bytes each; a tool matches any word in its name or description, ignoring ASCII case. Loads at most eight matches in name order. Loaded tools become available on your next request. Set reload to true, with or without words, to ask every MCP server to list its tools again: the reload returns at once, and a server's new tools can be found with a later find_tools call.";
pub const find_tools_schema = "{\"type\":\"object\",\"properties\":{\"words\":{\"type\":\"string\",\"description\":\"One to eight search words separated by ASCII spaces; each word is at most 64 bytes. Required unless reload is true.\"},\"reload\":{\"type\":\"boolean\",\"description\":\"true asks every configured MCP server to list its tools again. This call's search uses the tools offered now.\"}},\"additionalProperties\":false}";

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
    "The spec may only narrow your own tools and permission mode. " ++
    "An attached agent's final answer arrives as a Message that starts your next turn. A standalone agent's answer stays in its own Session, so ask it in the task to reply with message_agent. Either way, end your turn instead of waiting.";
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
        if (std.mem.eql(u8, entry.field, "workspace") or std.mem.eql(u8, entry.field, "provider") or entry.kind == .app_tools) continue;
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

pub const Owner = enum { rui, provider, mcp, app };

/// How the Host may repeat an app call after a restart. Only `safe` may be repeated; `unsafe` is reported
/// as "may have run" and never re-run (design U6, cut-off).
pub const Replay = enum { unsafe, safe };

/// Policy an app record carries. Only `owner = app` uses it; every other record holds the zero policy,
/// so no other digest or row changes. All three fields are part of the record digest.
pub const AppPolicy = struct {
    replay: Replay = .unsafe,
    /// Restarts a safe call may take before it fails with `restart_limit`. Ignored unless `replay` is safe.
    restart_limit: u8 = default_app_restart_limit,
    /// Milliseconds an unclaimed call waits from the moment it is ready before it fails.
    wait_ms: u32 = default_app_wait_ms,

    /// The policy as the Store keeps it and the digest hashes it. An unsafe call is never repeated, so
    /// its restart limit is 0 whatever the declaration said: the digest does not depend on it.
    pub fn canonical(self: AppPolicy) AppPolicy {
        var policy = self;
        if (self.replay == .unsafe) policy.restart_limit = 0;
        return policy;
    }

    /// Whether the bounds the Store's CHECKs enforce hold for this policy.
    pub fn valid(self: AppPolicy) bool {
        return self.restart_limit <= max_app_restart_limit and self.wait_ms >= min_app_wait_ms and self.wait_ms <= max_app_wait_ms;
    }
};

pub const default_app_restart_limit: u8 = 3;
pub const default_app_wait_ms: u32 = 900_000;
pub const max_app_restart_limit: u8 = 16;
pub const min_app_wait_ms: u32 = 1_000;
pub const max_app_wait_ms: u32 = 3_600_000;

pub const max_server_bytes = tool_name.max_bytes;

pub const Record = struct {
    /// The offered name: the model's name for the tool and the key every Session reads.
    name: []const u8,
    /// The name the owning server listed, read through `remoteName`. Empty means the offered name,
    /// which is every built-in and every unprefixed MCP tool; only a prefixed MCP tool differs (offered.zig).
    remote_name: []const u8 = "",
    description: []const u8 = "",
    input_schema: []const u8 = "",
    owner: Owner,
    server: []const u8 = "",
    /// Set only on `owner = app`; the zero policy on every other owner.
    app: AppPolicy = .{},

    pub fn runner(self: *const Record) Runner {
        return Runner.of(self);
    }

    /// The one reader of the remote name: the name a server listed, which a tools/call sends.
    pub fn remoteName(self: *const Record) []const u8 {
        return remoteNameOf(self.name, self.remote_name);
    }

    /// The remote name as the Store keeps it: empty when it is the offered name.
    pub fn storedRemoteName(self: *const Record) []const u8 {
        return if (std.mem.eql(u8, self.remoteName(), self.name)) "" else self.remote_name;
    }
};

/// The rule behind `Record.remoteName`, for a row that holds the offered name and its stored remote name.
pub fn remoteNameOf(name: []const u8, remote_name: []const u8) []const u8 {
    return if (remote_name.len == 0) name else remote_name;
}

pub const max_name_bytes = tool_name.max_bytes;

pub const max_tools = tool_name.max_tools;

pub fn recordDigest(member: *const Record) [32]u8 {
    return (RecordIdentity{
        .name = member.name,
        .remote_name = member.remote_name,
        .owner = member.owner,
        .server = member.server,
        .description = content_string.digest(member.description),
        .input_schema = content_string.digest(member.input_schema),
        .app = if (member.owner == .app) member.app else null,
    }).digest();
}

pub const RecordIdentity = struct {
    name: []const u8,
    /// Empty or equal to `name` for every record but a prefixed MCP tool; see `Record.remote_name`.
    remote_name: []const u8,
    owner: Owner,
    server: []const u8,
    description: [32]u8,
    input_schema: [32]u8,
    /// Non-null exactly for `owner = app`, which joins the identity under its own tag; see `Record.app`.
    /// Required, so every caller that rebuilds an identity from stored rows states its policy.
    app: ?AppPolicy,

    pub fn digest(self: *const RecordIdentity) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hashField(&hash, "rui/tool-record/v1");
        hashField(&hash, self.name);
        // A remote name joins the identity only when it differs from the offered name, under its own tag,
        // so every record without one keeps the digest it had before remote names existed.
        if (self.remote_name.len != 0 and !std.mem.eql(u8, self.remote_name, self.name)) {
            hashField(&hash, "rui/tool-record/remote-name");
            hashField(&hash, self.remote_name);
        }
        hashField(&hash, @tagName(self.owner));
        hashField(&hash, self.server);
        hash.update(&self.description);
        hash.update(&self.input_schema);
        if (self.app) |policy| {
            const stored = policy.canonical();
            hashField(&hash, "rui/tool-record/app-policy");
            hashField(&hash, @tagName(stored.replay));
            hashField(&hash, &.{stored.restart_limit});
            var wait: [4]u8 = undefined;
            std.mem.writeInt(u32, &wait, stored.wait_ms, .big);
            hashField(&hash, &wait);
        }
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

    /// A missing tool's refusal. It records which configured servers had no tools
    /// instead of borrowing the set, because a later save may free that set;
    /// `configured_servers` must outlive it (the Host's settings own those names).
    pub const MissingTool = struct {
        name: Bounded(tool_name.max_bytes) = .{},
        empty: std.bit_set.IntegerBitSet(max_servers) = .empty,
        servers: []const []const u8 = &.{},

        pub fn write(self: *const MissingTool, out: *std.Io.Writer) !void {
            try out.print("spec.tools: {s} is not a known tool", .{self.name.slice()});
            var empty = self.empty.iterator(.{});
            const first = empty.next() orelse return;
            if (empty.next()) |second| {
                try out.print("; MCP servers {s}, {s}", .{ self.servers[first], self.servers[second] });
                while (empty.next()) |server| try out.print(", {s}", .{self.servers[server]});
                try out.writeAll(" are unavailable and may provide it");
            } else try out.print("; MCP server {s} is unavailable and may provide it", .{self.servers[first]});
        }
    };

    /// At most this many configured servers; host settings caps MCP servers below it.
    pub const max_servers = 16;

    pub fn missingTool(self: *const HostToolSet, name: []const u8) MissingTool {
        var detail: MissingTool = .{ .servers = self.configured_servers };
        detail.name.set(name) catch unreachable;
        for (self.configured_servers, 0..) |server, at| {
            for (self.records) |entry| {
                if (entry.owner == .mcp and std.mem.eql(u8, entry.server, server)) break;
            } else detail.empty.set(at);
        }
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
        try self.missingTool(name).write(out);
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
            if (!tool_name.valid(each.name) or !validServer(each) or !validRemoteName(each)) return false;
            if (each.owner == .app and !each.app.valid()) return false;
            if (index != 0 and std.mem.order(u8, self.records[index - 1].name, each.name) != .lt) return false;
            if (!std.mem.eql(u8, &digest, &recordDigest(each))) return false;
        }
        return true;
    }
};

pub fn validServer(each: *const Record) bool {
    return if (each.owner == .mcp) tool_name.valid(each.server) else each.server.len == 0;
}

/// Empty or the offered name for a built-in. An MCP tool's remote name is the name its server listed,
/// valid as a tool name, and its offered name is that name or `<server>__<remote name>`.
pub fn validRemoteName(each: *const Record) bool {
    if (each.remote_name.len == 0 or std.mem.eql(u8, each.name, each.remote_name)) return true;
    if (each.owner != .mcp or !tool_name.valid(each.remote_name)) return false;
    const prefix = each.server.len + prefix_separator.len;
    return each.name.len == prefix + each.remote_name.len and
        std.mem.startsWith(u8, each.name, each.server) and
        std.mem.eql(u8, each.name[each.server.len..][0..prefix_separator.len], prefix_separator) and
        std.mem.endsWith(u8, each.name, each.remote_name);
}

/// Joins a server name and a listed name into the offered name of a tool whose listed name clashes.
pub const prefix_separator = "__";

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
    app,

    /// The offer comes from the frozen tool set of the model operation.
    pub fn resultProfile(self: Runner, bash_offered: bool) Profile {
        return switch (self) {
            .bash => .{ .excerpt_bytes = max_result_excerpt_bytes, .retain = true },
            .mcp => .{ .excerpt_bytes = 10_000, .retain = bash_offered },
            .read_image => .{ .excerpt_bytes = 0, .retain = false },
            .core => .{ .excerpt_bytes = 0, .retain = false }, // Core pagers own their already-shaped windows.
            // An app result is model-facing text from the app, shaped like an MCP result.
            .app => .{ .excerpt_bytes = 10_000, .retain = bash_offered },
            .provider => unreachable,
        };
    }

    pub fn beforeAdmissionStopText(self: Runner) []const u8 {
        return switch (self) {
            .bash => @import("bash_action_text.zig").stopped_before_admission,
            .read_image => @import("action_text.zig").stopped_before_admission,
            .mcp => @import("mcp/action_text.zig").stopped_before_admission,
            .app => @import("action_text.zig").stopped_before_admission,
            .core => @import("action_text.zig").stopped_before_admission,
            .provider => unreachable,
        };
    }

    pub fn stoppedText(self: Runner, _: anytype, result: []const u8) []const u8 {
        return switch (self) {
            .bash => @import("bash_action_text.zig").stopped_before_admission,
            .read_image => "Stopped before this image read completed.",
            .mcp => result,
            .app => "Stopped before the app returned a result.",
            .core, .provider => unreachable,
        };
    }

    pub fn indeterminateText(self: Runner) []const u8 {
        return switch (self) {
            .bash => @import("bash_action_text.zig").indeterminate,
            .read_image => "The Host stopped before saving this image read result. The read may have completed; it was not automatically repeated.",
            .mcp => @import("mcp/action_text.zig").indeterminate,
            .app => "The Host stopped while this app call was running. The app may have run it; it was not automatically repeated.",
            .core, .provider => unreachable,
        };
    }

    pub fn of(tool: *const Record) Runner {
        if (ownerRunner(tool.owner)) |runner| return runner;
        return builtInRunner(tool.name);
    }
};

/// The one owner of runner derivation. An owner listed here fixes its runner; any other record takes
/// the runner of its built-in name, and a name that is not built-in runs as Bash. `Runner.of` and the
/// SQL in `sql` below both read these tables, so a runner cannot be derived one way in Zig and another in SQL.
pub const owner_runners = [_]struct { owner: Owner, runner: Runner }{
    .{ .owner = .mcp, .runner = .mcp },
    .{ .owner = .provider, .runner = .provider },
    .{ .owner = .app, .runner = .app },
};

pub fn ownerRunner(owner: Owner) ?Runner {
    for (owner_runners) |rule| if (rule.owner == owner) return rule.runner;
    return null;
}

pub fn builtInRunner(name: []const u8) Runner {
    for (built_in_rows.values) |row| {
        if (std.mem.eql(u8, name, row.record.name)) return row.runner;
    }
    return default_runner;
}

/// SQL predicates over a tool row's `owner` and `name` expressions, generated from the tables above.
/// A built-in name derives the runner only on a row whose owner has no owner rule, as `Runner.of` does.
pub const sql = struct {
    /// `owner` names an owner with no owner rule, so the row's built-in name decides its runner.
    fn nameRuledOwner(comptime owner: []const u8) []const u8 {
        comptime {
            @setEvalBranchQuota(100_000);
            var owners: []const u8 = "";
            for (std.enums.values(Owner)) |value| {
                if (ownerRunner(value) != null) continue;
                owners = owners ++ (if (owners.len == 0) "" else ",") ++ "'" ++ @tagName(value) ++ "'";
            }
            return owner ++ " IN (" ++ owners ++ ")";
        }
    }

    fn ownerTest(comptime owner: []const u8, comptime runner: Runner) []const u8 {
        comptime {
            @setEvalBranchQuota(100_000);
            var owners: []const u8 = "";
            for (owner_runners) |rule| {
                if (rule.runner != runner) continue;
                owners = owners ++ (if (owners.len == 0) "" else ",") ++ "'" ++ @tagName(rule.owner) ++ "'";
            }
            return if (owners.len == 0) "" else owner ++ " IN (" ++ owners ++ ")";
        }
    }

    /// True when the row's owner has no owner rule and its name is a built-in whose row derives `runner`.
    pub fn builtInTest(comptime owner: []const u8, comptime name: []const u8, comptime runner: Runner) []const u8 {
        comptime {
            @setEvalBranchQuota(100_000);
            var names: []const u8 = "";
            for (built_in_rows.values) |row| {
                if (row.runner != runner) continue;
                names = names ++ (if (names.len == 0) "" else ",") ++ "'" ++ row.record.name ++ "'";
            }
            if (names.len == 0) return "";
            return nameRuledOwner(owner) ++ " AND " ++ name ++ " IN (" ++ names ++ ")";
        }
    }

    /// True exactly when `Runner.of` returns `runner` for the row. Bash, the runner of a name that is not
    /// built-in, is the complement of every other runner.
    pub fn runnerTest(comptime owner: []const u8, comptime name: []const u8, comptime runner: Runner) []const u8 {
        comptime {
            @setEvalBranchQuota(100_000);
            if (runner == default_runner) return "NOT " ++ notDefaultTest(owner, name);
            const by_owner = ownerTest(owner, runner);
            const by_name = builtInTest(owner, name, runner);
            if (by_owner.len == 0 and by_name.len == 0) @compileError("no rule derives runner " ++ @tagName(runner));
            if (by_owner.len == 0) return "(" ++ by_name ++ ")";
            if (by_name.len == 0) return "(" ++ by_owner ++ ")";
            return "(" ++ by_owner ++ " OR " ++ by_name ++ ")";
        }
    }

    /// True exactly when `Runner.of` returns any runner other than Bash.
    pub fn notDefaultTest(comptime owner: []const u8, comptime name: []const u8) []const u8 {
        comptime {
            @setEvalBranchQuota(100_000);
            var out: []const u8 = "";
            for (std.enums.values(Runner)) |runner| {
                if (runner == default_runner) continue;
                out = out ++ (if (out.len == 0) "" else " OR ") ++ runnerTest(owner, name, runner);
            }
            return "(" ++ out ++ ")";
        }
    }

    /// The runner of the row, exactly as `Runner.of`: a CASE with one arm per runner and Bash for the rest.
    pub fn runnerOf(comptime owner: []const u8, comptime name: []const u8) []const u8 {
        comptime {
            @setEvalBranchQuota(100_000);
            var out: []const u8 = "CASE";
            for (std.enums.values(Runner)) |runner| {
                if (runner == default_runner) continue;
                out = out ++ " WHEN " ++ runnerTest(owner, name, runner) ++ " THEN '" ++ @tagName(runner) ++ "'";
            }
            return out ++ " ELSE '" ++ @tagName(default_runner) ++ "' END";
        }
    }
};

/// The runner of a rui-owned name that is not built-in, and the SQL CASE's fallback.
pub const default_runner: Runner = .bash;

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
    return std.mem.eql(u8, @tagName(a.owner), @tagName(b.owner)) and a.storedRemoteName().len == 0 and
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
    const snapshot: Snapshot = .{ .record = .{ .name = base.name, .owner = .mcp, .server = base.server, .description = base.description, .input_schema = base.input_schema }, .digest = expected };
    const snapshots = [_]Snapshot{snapshot};
    var selected: [2][32]u8 = undefined;
    selectDigests(&.{base}, &snapshots, selected[0..1]);
    try std.testing.expectEqualSlices(u8, &recordDigest(&base), &selected[0]);

    var changes: [4]Record = .{ base, base, base, base };
    changes[0].name = "fetch_other";
    changes[1].description = "Fetch another page.";
    changes[2].input_schema = "{}";
    changes[3].server = "other";
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

    try expectAppPolicyDigests();
}

test "a remote name joins a digest only when it differs from the offered name" {
    const plain: Record = .{ .name = "search", .owner = .mcp, .server = "docs", .input_schema = "{}" };
    var explicit = plain;
    explicit.remote_name = "search";
    try std.testing.expectEqualSlices(u8, &recordDigest(&plain), &recordDigest(&explicit));
    try std.testing.expectEqualStrings("", plain.storedRemoteName());
    try std.testing.expectEqualStrings("", explicit.storedRemoteName());
    const prefixed: Record = .{ .name = "docs__search", .remote_name = "search", .owner = .mcp, .server = "docs", .input_schema = "{}" };
    try std.testing.expectEqualStrings("search", prefixed.remoteName());
    try std.testing.expectEqualStrings("search", prefixed.storedRemoteName());
    try std.testing.expect(!std.mem.eql(u8, &recordDigest(&plain), &recordDigest(&prefixed)));
    try std.testing.expect(validRemoteName(&prefixed));
    try std.testing.expect(!validRemoteName(&.{ .name = "docs__search", .remote_name = "search", .owner = .rui, .input_schema = "{}" }));
}

fn expectAppPolicyDigests() !void {
    const base: Record = .{ .name = "ask", .owner = .app, .input_schema = "{}", .app = .{} };
    const base_digest = recordDigest(&base);
    // The default app record's digest is pinned: a change to canonical() or to the app policy tag fails here.
    const default_app_pinned = [32]u8{
        0x2B, 0xA9, 0x41, 0xA8, 0x68, 0x77, 0x99, 0xED, 0x64, 0xC2, 0xA8, 0x0B, 0xD4, 0x9D, 0x0E, 0x0A,
        0x2F, 0xAD, 0x46, 0xC1, 0xAC, 0xAE, 0xED, 0x39, 0x3E, 0x09, 0x13, 0x6D, 0x3F, 0xAE, 0x2C, 0xCD,
    };
    try std.testing.expectEqualSlices(u8, &default_app_pinned, &base_digest);
    const variants = [_]AppPolicy{
        .{ .replay = .safe, .restart_limit = 3, .wait_ms = default_app_wait_ms },
        .{ .replay = .safe, .restart_limit = 4, .wait_ms = default_app_wait_ms },
        .{ .replay = .unsafe, .restart_limit = 3, .wait_ms = default_app_wait_ms + 1 },
    };
    var digests: [variants.len][32]u8 = undefined;
    for (variants, &digests) |policy, *digest| {
        var changed = base;
        changed.app = policy;
        digest.* = recordDigest(&changed);
        try std.testing.expect(!std.mem.eql(u8, &base_digest, digest));
    }
    for (digests, 0..) |first, index| for (digests[index + 1 ..]) |second| try std.testing.expect(!std.mem.eql(u8, &first, &second));

    // Only app records read the policy: a non-app record ignores a stray policy, and its digest is pinned.
    var built_in: Record = .{ .name = "bash", .owner = .rui, .input_schema = "{}" };
    const plain = recordDigest(&built_in);
    built_in.app = .{ .replay = .safe, .restart_limit = 9, .wait_ms = 5_000 };
    try std.testing.expectEqualSlices(u8, &plain, &recordDigest(&built_in));
    const pinned = [32]u8{
        0x84, 0x3F, 0x40, 0x9E, 0x5E, 0x79, 0x2F, 0x28, 0xE0, 0x19, 0x6D, 0x4D, 0x23, 0x2B, 0xDD, 0x9D,
        0xAC, 0x49, 0x33, 0x29, 0x30, 0x81, 0xCA, 0x0A, 0x97, 0x18, 0x68, 0x4C, 0xE9, 0xC3, 0x31, 0xFC,
    };
    try std.testing.expectEqualSlices(u8, &pinned, &plain);

    // An unsafe call is never repeated, so its digest does not depend on the restart limit it declared.
    const unsafe: Record = .{ .name = "ask", .owner = .app, .input_schema = "{}", .app = .{ .replay = .unsafe, .restart_limit = 0, .wait_ms = default_app_wait_ms } };
    const unsafe_digest = recordDigest(&unsafe);
    for ([_]u8{ 1, default_app_restart_limit, max_app_restart_limit }) |limit| {
        var declared = unsafe;
        declared.app.restart_limit = limit;
        try std.testing.expectEqualSlices(u8, &unsafe_digest, &recordDigest(&declared));
    }
    try std.testing.expect(!(AppPolicy{ .restart_limit = max_app_restart_limit + 1 }).valid());
    try std.testing.expect((AppPolicy{ .restart_limit = max_app_restart_limit, .wait_ms = max_app_wait_ms }).valid());
    try std.testing.expect(!(AppPolicy{ .wait_ms = min_app_wait_ms - 1 }).valid());
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
            .bash, .mcp, .app, .read_image, .core => {
                for ([_]bool{ false, true }) |offer| {
                    try std.testing.expect(runner.resultProfile(offer).excerpt_bytes <= max_result_excerpt_bytes);
                }
            },
        }
    }
}

/// The app tools a lane root declares: one JSON array document, validated in this one place.
/// Every Store and Host path that accepts `appTools` calls `app_tools.parse`; no other path reads the document.
/// It lives with the records it builds, so the declaration adds no module beside the record owner.
pub const app_tools = struct {
    const shape = @import("mcp/shape.zig");

    /// Declared records per lane root. The Store's round budget for one configure is sized to this.
    pub const max_records = 16;
    /// The largest document `parse` accepts; a larger one is refused by name before it is read.
    pub const max_document_bytes = 64 * 1024;
    /// Bytes the parse may use for the document copy, the JSON tree and the saved text of one declaration.
    pub const arena_bytes = 512 * 1024;
    /// A declared set's names joined by commas: the widest text a reader of one declaration takes.
    pub const max_names_bytes = max_records * tool_name.max_bytes + max_records - 1;

    pub const Refusal = enum {
        invalid_app_tools,
        app_tools_too_large,
        invalid_app_tool_name,
        duplicate_app_tool_name,
        app_tool_built_in_clash,
        invalid_app_tool_policy,
    };

    /// A declaration that passed every check. Its slices point into the arena `parse` was given.
    pub const Declaration = struct {
        /// Sorted by name, which `HostToolSet` requires for `find` and `valid`.
        records: []Record,
        digests: [][32]u8,

        pub fn toolSet(declaration: *const Declaration) HostToolSet {
            return .{ .records = declaration.records, .digests = declaration.digests };
        }
    };

    pub const Parsed = union(enum) { declared: Declaration, refused: Refusal };

    const member_names = [_][]const u8{ "name", "description", "input_schema", "replay", "restart_limit", "wait_ms" };

    /// Validates `bytes` as a declaration. `arena` owns every slice the result points to and must outlive it.
    /// An arena that runs out is a refusal by size, never a partial declaration.
    pub fn parse(arena: std.mem.Allocator, bytes: []const u8) Parsed {
        if (bytes.len > max_document_bytes) return .{ .refused = .app_tools_too_large };
        return parseInArena(arena, bytes) catch |err| switch (err) {
            error.OutOfMemory => .{ .refused = .app_tools_too_large },
            error.InvalidAppTools => .{ .refused = .invalid_app_tools },
            error.InvalidAppToolName => .{ .refused = .invalid_app_tool_name },
            error.DuplicateAppToolName => .{ .refused = .duplicate_app_tool_name },
            error.AppToolBuiltInClash => .{ .refused = .app_tool_built_in_clash },
            error.InvalidAppToolPolicy => .{ .refused = .invalid_app_tool_policy },
        };
    }

    const ParseError = error{ OutOfMemory, InvalidAppTools, InvalidAppToolName, DuplicateAppToolName, AppToolBuiltInClash, InvalidAppToolPolicy };

    fn parseInArena(arena: std.mem.Allocator, bytes: []const u8) ParseError!Parsed {
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{ .allocate = .alloc_if_needed, .parse_numbers = false }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidAppTools,
        };
        if (value != .array or value.array.items.len > max_records) return error.InvalidAppTools;
        const records = try arena.alloc(Record, value.array.items.len);
        for (value.array.items, records) |item, *entry| entry.* = try recordOf(arena, item);
        std.mem.sort(Record, records, {}, byName);
        for (records, 0..) |entry, index| {
            if (index != 0 and std.mem.eql(u8, records[index - 1].name, entry.name)) return error.DuplicateAppToolName;
        }
        const digests = try arena.alloc([32]u8, records.len);
        for (records, digests) |*entry, *digest| digest.* = recordDigest(entry);
        const declaration: Declaration = .{ .records = records, .digests = digests };
        std.debug.assert(declaration.toolSet().valid());
        return .{ .declared = declaration };
    }

    fn byName(_: void, a: Record, b: Record) bool {
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    fn recordOf(arena: std.mem.Allocator, item: std.json.Value) ParseError!Record {
        if (item != .object) return error.InvalidAppTools;
        var members = item.object.iterator();
        while (members.next()) |member| {
            var known = false;
            for (member_names) |name| known = known or std.mem.eql(u8, member.key_ptr.*, name);
            if (!known) return error.InvalidAppTools;
        }
        const name = item.object.get("name") orelse return error.InvalidAppTools;
        if (name != .string) return error.InvalidAppTools;
        if (!tool_name.valid(name.string)) return error.InvalidAppToolName;
        if (built_in_tool_set.find(name.string) != null) return error.AppToolBuiltInClash;
        const description = item.object.get("description") orelse return error.InvalidAppTools;
        if (description != .string or !tool_presentation.ToolPresentation.validDescription(description.string)) return error.InvalidAppTools;
        const schema = item.object.get("input_schema") orelse return error.InvalidAppTools;
        if (schema != .object) return error.InvalidAppTools;
        const schema_text = try std.json.Stringify.valueAlloc(arena, schema, .{});
        shape.check(schema_text) catch return error.InvalidAppTools;
        const policy: AppPolicy = .{
            .replay = try replayOf(item.object.get("replay")),
            .restart_limit = try integerOf(u8, item.object.get("restart_limit"), default_app_restart_limit),
            .wait_ms = try integerOf(u32, item.object.get("wait_ms"), default_app_wait_ms),
        };
        if (!policy.valid()) return error.InvalidAppToolPolicy;
        return .{
            .name = name.string,
            .description = description.string,
            .input_schema = schema_text,
            .owner = .app,
            .app = policy,
        };
    }

    fn replayOf(value: ?std.json.Value) ParseError!Replay {
        const found = value orelse return .unsafe;
        if (found != .string) return error.InvalidAppToolPolicy;
        return std.meta.stringToEnum(Replay, found.string) orelse error.InvalidAppToolPolicy;
    }

    fn integerOf(comptime Int: type, value: ?std.json.Value, default: Int) ParseError!Int {
        const found = value orelse return default;
        // Numbers stay as their written text so a schema keeps its exact values; a policy integer is plain digits.
        if (found != .number_string) return error.InvalidAppToolPolicy;
        return std.fmt.parseInt(Int, found.number_string, 10) catch error.InvalidAppToolPolicy;
    }

    // SH-143: an input schema keeps every number exactly as written (integer, decimal and exponent forms), so its text
    // and record digest never depend on floating-point rounding; policy integers accept only plain digits.
    test "SH-143 app tools keep schema numbers exactly as written" {
        const arena_memory = try std.testing.allocator.alloc(u8, arena_bytes);
        defer std.testing.allocator.free(arena_memory);
        const schemas = [_][]const u8{
            "{\"maximum\":9007199254740993}",
            "{\"maximum\":9007199254740993e0}",
            "{\"multipleOf\":0.1000000000000000055511151231257827}",
            "{\"minimum\":-1.5E+3}",
        };
        var digests: [schemas.len][32]u8 = undefined;
        for (schemas, &digests) |schema, *digest| {
            var fixed: std.heap.FixedBufferAllocator = .init(arena_memory);
            var document: [256]u8 = undefined;
            const text = try std.fmt.bufPrint(&document, "[{{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{s}}}]", .{schema});
            const parsed = parse(fixed.allocator(), text);
            try std.testing.expect(parsed == .declared);
            try std.testing.expectEqualStrings(schema, parsed.declared.records[0].input_schema);
            digest.* = parsed.declared.digests[0];
            // The same text declared again keeps the same digest, so a repeated declaration deduplicates.
            var again: std.heap.FixedBufferAllocator = .init(arena_memory[arena_bytes / 2 ..]);
            const reparsed = parse(again.allocator(), text);
            try std.testing.expectEqualSlices(u8, digest, &reparsed.declared.digests[0]);
        }
        try std.testing.expect(!std.mem.eql(u8, &digests[0], &digests[1]));
        var fixed: std.heap.FixedBufferAllocator = .init(arena_memory);
        for ([_][]const u8{ "5.0", "5e0", "-1", "\"5\"" }) |limit| {
            fixed.reset();
            var document: [256]u8 = undefined;
            const text = try std.fmt.bufPrint(&document, "[{{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{{}},\"replay\":\"safe\",\"restart_limit\":{s}}}]", .{limit});
            try std.testing.expectEqual(Parsed{ .refused = .invalid_app_tool_policy }, parse(fixed.allocator(), text));
        }
    }

    // SH-143: the declaration validator accepts one well-formed list of records and names the refusal of every other
    // document, over the whole domain of names, policies, sizes and counts.
    test "SH-143 app tools validate one declaration with named refusals over its domain" {
        const arena_memory = try std.testing.allocator.alloc(u8, arena_bytes);
        defer std.testing.allocator.free(arena_memory);
        const ok = "{\"name\":\"lookup\",\"description\":\"Look up a thing\",\"input_schema\":{\"type\":\"object\"}}";
        const cases = [_]struct { document: []const u8, want: ?Refusal }{
            .{ .document = "[]", .want = null },
            .{ .document = "[" ++ ok ++ "]", .want = null },
            .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{\"type\":\"object\"},\"replay\":\"safe\",\"restart_limit\":5,\"wait_ms\":2000}]", .want = null },
            .{ .document = "[{\"name\":\"has.dot\",\"description\":\"d\",\"input_schema\":{}}]", .want = .invalid_app_tool_name },
            .{ .document = "[" ++ ok ++ "," ++ ok ++ "]", .want = .duplicate_app_tool_name },
            .{ .document = "[{\"name\":\"bash\",\"description\":\"d\",\"input_schema\":{}}]", .want = .app_tool_built_in_clash },
            .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{},\"wait_ms\":0}]", .want = .invalid_app_tool_policy },
            .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{},\"restart_limit\":17}]", .want = .invalid_app_tool_policy },
            .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{},\"replay\":\"maybe\"}]", .want = .invalid_app_tool_policy },
            .{ .document = "[{\"name\":\"a\",\"description\":\"\",\"input_schema\":{}}]", .want = .invalid_app_tools },
            .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":[]}]", .want = .invalid_app_tools },
            .{ .document = "[{\"name\":\"a\",\"description\":\"d\",\"input_schema\":{},\"extra\":1}]", .want = .invalid_app_tools },
            .{ .document = "[{\"description\":\"d\",\"input_schema\":{}}]", .want = .invalid_app_tools },
            .{ .document = "{}", .want = .invalid_app_tools },
            .{ .document = "[", .want = .invalid_app_tools },
        };
        for (cases) |case| {
            var fixed: std.heap.FixedBufferAllocator = .init(arena_memory);
            const parsed = parse(fixed.allocator(), case.document);
            switch (parsed) {
                .declared => |declaration| {
                    try std.testing.expect(case.want == null);
                    try std.testing.expect(declaration.toolSet().valid());
                },
                .refused => |refusal| try std.testing.expectEqual(case.want.?, refusal),
            }
        }
        // The policy keeps its stated safe values; an unsafe call keeps restart_limit 0 (AppPolicy.canonical).
        var fixed: std.heap.FixedBufferAllocator = .init(arena_memory);
        const safe = parse(fixed.allocator(), cases[2].document).declared;
        try std.testing.expectEqual(Replay.safe, safe.records[0].app.replay);
        try std.testing.expectEqual(@as(u8, 5), safe.records[0].app.restart_limit);
        try std.testing.expectEqual(@as(u32, 2000), safe.records[0].app.wait_ms);
        var defaults: std.heap.FixedBufferAllocator = .init(arena_memory);
        const unsafe = parse(defaults.allocator(), "[" ++ ok ++ "]").declared;
        try std.testing.expectEqual(Replay.unsafe, unsafe.records[0].app.replay);
        try std.testing.expectEqual(@as(u8, 0), unsafe.records[0].app.canonical().restart_limit);
        // Size: a document over the cap is refused before it is read, and an arena too small is refused by size.
        const too_long = try std.testing.allocator.alloc(u8, max_document_bytes + 1);
        defer std.testing.allocator.free(too_long);
        @memset(too_long, ' ');
        var small_memory: [64]u8 = undefined;
        var small: std.heap.FixedBufferAllocator = .init(&small_memory);
        try std.testing.expectEqual(Refusal.app_tools_too_large, parse(fixed.allocator(), too_long).refused);
        try std.testing.expectEqual(Refusal.app_tools_too_large, parse(small.allocator(), "[" ++ ok ++ "]").refused);
    }
};

test {
    _ = app_tools;
}
