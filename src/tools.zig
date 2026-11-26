const std = @import("std");
const tool_line = @import("tool_line.zig");
const protocol = @import("protocol.zig");
pub const core_tools = @import("core_tools.zig");

pub const bash_max_command_bytes = @import("tool_record.zig").bash_max_command_bytes;
pub const bash_max_stdin_bytes = @import("tool_record.zig").bash_max_stdin_bytes;
pub const Owner = @import("tool_record.zig").Owner;
pub const max_server_bytes = @import("tool_record.zig").max_server_bytes;
pub const Record = @import("tool_record.zig").Record;
pub const max_name_bytes = @import("tool_record.zig").max_name_bytes;
pub const max_tools = @import("tool_record.zig").max_tools;
pub const recordDigest = @import("tool_record.zig").recordDigest;
pub const remoteNameOf = @import("tool_record.zig").remoteNameOf;
pub const RecordIdentity = @import("tool_record.zig").RecordIdentity;
pub const SetDigest = @import("tool_record.zig").SetDigest;
pub const HostToolSet = @import("tool_record.zig").HostToolSet;
pub const validServer = @import("tool_record.zig").validServer;
pub const max_host_tool_records = @import("tool_record.zig").max_host_tool_records;
pub const bash_record = @import("tool_record.zig").bash_record;
pub const find_tools_record = @import("tool_record.zig").find_tools_record;
pub const message_agent_record = @import("tool_record.zig").message_agent_record;
pub const read_image_record = @import("tool_record.zig").read_image_record;
pub const read_transcript_record = @import("tool_record.zig").read_transcript_record;
pub const skill_record = @import("tool_record.zig").skill_record;
pub const start_agent_record = @import("tool_record.zig").start_agent_record;
pub const web_search_record = @import("tool_record.zig").web_search_record;
pub const Runner = @import("tool_record.zig").Runner;
pub const record = @import("tool_record.zig").record;
pub const built_in_tool_set = @import("tool_record.zig").built_in_tool_set;
pub const Offered = @import("tool_record.zig").Offered;

pub const Description = @import("tool_record.zig").Description;

pub const BashArguments = @import("call_classification.zig").BashArguments;
pub const CallFacts = @import("call_classification.zig").CallFacts;
pub const BashProblem = @import("call_classification.zig").BashProblem;
pub const inspectCall = @import("call_classification.zig").inspectCall;
pub const removed_tool_result = @import("call_classification.zig").removed_tool_result;
pub const rejectionResult = @import("call_classification.zig").rejectionResult;
pub const classifyCall = @import("call_classification.zig").classifyCall;
pub const validBashArguments = @import("call_classification.zig").validBashArguments;
pub const inspectBashArguments = @import("call_classification.zig").inspectBashArguments;
pub const writeBashCommand = @import("call_classification.zig").writeBashCommand;
pub const writeBashStdin = @import("call_classification.zig").writeBashStdin;
pub const BashCheck = @import("call_classification.zig").BashCheck;
pub const checkBashArguments = @import("call_classification.zig").checkBashArguments;
pub const BashParseProgress = @import("call_classification.zig").BashParseProgress;
pub const BashParser = @import("call_classification.zig").BashParser;
pub const isBashDescriptorError = @import("call_classification.zig").isBashDescriptorError;

pub const Tool = @import("tool_record.zig").Tool;
pub const builtIn = @import("tool_record.zig").builtIn;
pub const ToolSet = @import("tool_record.zig").ToolSet;

test "read_transcript descriptions stream IDs and never reject runtime arguments at settlement" {
    const Name = struct {
        at: usize = 0,
        pub fn next(self: *@This()) !?u8 {
            const name = "read_transcript";
            if (self.at == name.len) return null;
            defer self.at += 1;
            return name[self.at];
        }
    };
    const spaces: [700]u8 = @splat(' ');
    const large = "{\"kinds\":[\"assistant\"]," ++ spaces ++ "\"id\":\"k7m2qx\"}";
    const Case = struct { arguments: []const u8, note: []const u8 };
    for ([_]Case{
        .{ .arguments = "{}", .note = "Read own transcript" },
        .{ .arguments = "{\"id\":\"k7m2qx\"}", .note = "Read k7m2qx's transcript" },
        .{ .arguments = large, .note = "Read k7m2qx's transcript" },
        .{ .arguments = "{\"kinds\":[\"assistant\",\"call\"],\"id\":\"k7m2q\\u0078\"}", .note = "Read k7m2qx's transcript" },
        .{ .arguments = "{\"limit\":0}", .note = "Read own transcript" },
        .{ .arguments = "not json", .note = "Read own transcript" },
        .{ .arguments = "{\"id\":123}", .note = "Read own transcript" },
    }) |case| {
        var name: Name = .{};
        var arguments: TestSource = .{ .bytes = case.arguments };
        const offered = Offered{ .names = "read_transcript" };
        const facts = try inspectCall(&name, "read_transcript".len, &arguments, &offered);
        try std.testing.expectEqual(@as(?protocol.ProposalRejection, null), classifyCall(&facts));
        // The call keeps the Session it named; its line is derived from that.
        const line = (try tool_line.of(.{ .name = "read_transcript", .subject = facts.subject() })).?;
        var out: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out);
        try line.writePlain(&writer);
        try std.testing.expectEqualStrings(case.note, writer.buffered());
        try std.testing.expect(facts.label() == null);
    }
    try std.testing.expectEqual(Runner.core, Runner.of(&read_transcript_record));
}

test "a call is checked against the offered records before its arguments" {
    const Source = struct {
        bytes: []const u8,
        index: usize = 0,
        pub fn next(self: *@This()) !?u8 {
            if (self.index == self.bytes.len) return null;
            defer self.index += 1;
            return self.bytes[self.index];
        }
    };
    const Case = struct { name: []const u8, arguments: []const u8, offered: []const u8, expected: ?protocol.ProposalRejection, described: bool = false, withdrawn: bool = false, removed: bool = false };
    const valid = "{\"cmd\":\"true\",\"description\":\"Run true\"}";
    const bash_only = "bash";
    for ([_]Case{
        .{ .name = "bash", .arguments = valid, .offered = bash_only, .expected = null, .described = true },
        .{ .name = "bash", .arguments = "{}", .offered = bash_only, .expected = .invalid_arguments },
        .{ .name = "bash", .arguments = valid, .offered = "", .expected = .unknown_tool, .described = true },
        .{ .name = "bash", .arguments = "{}", .offered = "web_search", .expected = .unknown_tool },
        .{ .name = "web_search", .arguments = "{}", .offered = "bash,web_search,message_agent,start_agent,read_transcript,find_tools,skill", .expected = .unknown_tool },
        .{ .name = "", .arguments = "{}", .offered = "", .expected = .unknown_tool },
        .{ .name = "bas", .arguments = valid, .offered = "bash,web_search,message_agent,start_agent,read_transcript,find_tools,skill", .expected = .unknown_tool },
        .{ .name = "bashx", .arguments = valid, .offered = "bash,web_search,message_agent,start_agent,read_transcript,find_tools,skill", .expected = .unknown_tool },
        .{ .name = &(@as([max_name_bytes + 1]u8, @splat('b'))), .arguments = valid, .offered = "bash,web_search,message_agent,start_agent,read_transcript,find_tools,skill", .expected = .unknown_tool },
        .{ .name = "bash", .arguments = valid, .offered = "", .withdrawn = true, .expected = .unknown_tool, .described = true, .removed = true },
        .{ .name = "web_search", .arguments = "{}", .offered = "", .withdrawn = true, .expected = .unknown_tool },
    }) |case| {
        var name: Source = .{ .bytes = case.name };
        var arguments: TestSource = .{ .bytes = case.arguments };
        const offered: Offered = .{ .names = case.offered, .historical_digests = &.{@import("content_string.zig").digest(case.name)}, .withdrawn = &.{case.withdrawn} };
        const facts = try inspectCall(&name, case.name.len, &arguments, &offered);
        try std.testing.expectEqual(case.expected, classifyCall(&facts));
        try std.testing.expectEqual(case.described, facts.bashArguments() != null);
        try std.testing.expectEqual(case.removed, facts.removed);
    }
}

const TestSource = struct {
    bytes: []const u8,
    position: usize = 0,

    pub fn peek(self: *TestSource) !?u8 {
        return if (self.position == self.bytes.len) null else self.bytes[self.position];
    }

    pub fn next(self: *TestSource) !?u8 {
        const byte = (try self.peek()) orelse return null;
        self.position += 1;
        return byte;
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

    pub fn writeAll(self: *TestWriter, bytes: []const u8) !void {
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
    var name = struct {
        pub fn next(_: *@This()) !?u8 {
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
        pub fn next(self: *@This()) !?u8 {
            if (self.position == self.bytes.len) return null;
            defer self.position += 1;
            return self.bytes[self.position];
        }
    };
    const records = [_]Record{.{ .name = "fetch_page", .owner = .mcp, .server = "docs" }};
    const offered: Offered = .{ .names = "bash,fetch_page" };
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

test "find_tools is a core tool and settlement defers its words check" {
    const Name = struct {
        at: usize = 0,
        pub fn next(self: *@This()) !?u8 {
            const bytes = "find_tools";
            if (self.at == bytes.len) return null;
            defer self.at += 1;
            return bytes[self.at];
        }
    };
    for ([_][]const u8{ "{}", "{", "[]", "{\"words\":false}", "{\"words\":\"bash\"}" }) |bytes| {
        var name: Name = .{};
        var arguments: core_tools.SliceSource = .{ .bytes = bytes };
        const offered = Offered{ .names = "find_tools" };
        const facts = try inspectCall(&name, "find_tools".len, &arguments, &offered);
        try std.testing.expectEqualStrings(find_tools_record.name, facts.tool.?.name);
        try std.testing.expectEqual(Runner.core, facts.tool.?.runner());
        try std.testing.expect(facts.find_tools and facts.bash == null and facts.message_agent == null);
        try std.testing.expect(facts.label() == null and facts.subject() == null);
        name = .{};
        arguments = .{ .bytes = bytes };
        const hidden = Offered{};
        const unknown = try inspectCall(&name, "find_tools".len, &arguments, &hidden);
        try std.testing.expect(unknown.tool == null and unknown.find_tools);
    }
    try std.testing.expectEqual(Runner.core, Runner.of(&find_tools_record));
}

test "stop_action honors the offered core record and defers argument checks" {
    for ([_][]const u8{ "{\"action\":\"42\"}", "{\"session\":\"k7m2qx\"}", "not JSON" }) |text| {
        var name: TestSource = .{ .bytes = "stop_action" };
        var arguments: TestSource = .{ .bytes = text };
        const offered: Offered = .{ .names = "stop_action" };
        const facts = try inspectCall(&name, "stop_action".len, &arguments, &offered);
        try std.testing.expectEqual(@as(?protocol.ProposalRejection, null), classifyCall(&facts));
        try std.testing.expectEqual(Runner.core, facts.tool.?.runner());
        try std.testing.expect(facts.label() == null and facts.subject() == null);
        name = .{ .bytes = "stop_action" };
        arguments = .{ .bytes = text };
        const excluded: Offered = .{ .names = "read_transcript" };
        const refused = try inspectCall(&name, "stop_action".len, &arguments, &excluded);
        try std.testing.expectEqual(@as(?protocol.ProposalRejection, .unknown_tool), classifyCall(&refused));
    }
}

test "read_image classification uses offered built-in records and typed path arguments" {
    const Name = struct {
        at: usize = 0,
        pub fn next(self: *@This()) !?u8 {
            const name = read_image_record.name;
            if (self.at == name.len) return null;
            defer self.at += 1;
            return name[self.at];
        }
    };
    const Case = struct { arguments: []const u8, offered: bool = true, rejection: ?protocol.ProposalRejection = null };
    for ([_]Case{
        .{ .arguments = "{\"path\":\"pixel.png\"}" },
        .{ .arguments = "{\"path\":\"/tmp/pixel.jpg\"}" },
        .{ .arguments = "{}", .rejection = .invalid_arguments },
        .{ .arguments = "{\"path\":null}", .rejection = .invalid_arguments },
        .{ .arguments = "{\"path\":\"https://example.com/image.png\"}", .rejection = .invalid_arguments },
        .{ .arguments = "{\"path\":\"pixel.png\"}", .offered = false, .rejection = .unknown_tool },
    }) |case| {
        var name: Name = .{};
        var arguments: TestSource = .{ .bytes = case.arguments };
        const offered: Offered = .{ .names = if (case.offered) read_image_record.name else "" };
        const facts = try inspectCall(&name, read_image_record.name.len, &arguments, &offered);
        try std.testing.expectEqual(case.rejection, classifyCall(&facts));
        if (case.rejection == null) {
            try std.testing.expectEqual(Runner.read_image, facts.tool.?.runner());
            try std.testing.expect(facts.label() == null and facts.subject() == null);
        }
    }
}

test "PRW-13 watcher classification honors the frozen offer and strict arguments" {
    const Case = struct { text: []const u8, offered: bool = true, rejected: ?protocol.ProposalRejection = null };
    const name_text = "watch_github_pr";
    for ([_]Case{
        .{ .text = "{\"url\":\"https://github.com/org/repo/pull/42\"}" },
        .{ .text = "{\"url\":\"https://github.com/org/repo/pull/42\",\"account\":\"octocat\"}" },
        .{ .text = "{\"url\":\"https://github.com/org/repo/pull/42\",\"account\":null}", .rejected = .invalid_arguments },
        .{ .text = "{\"url\":\"https://github.com.evil/org/repo/pull/42\"}", .rejected = .invalid_arguments },
        .{ .text = "{\"url\":\"https://github.com/org/repo/pull/42\"}", .offered = false, .rejected = .unknown_tool },
    }) |case| {
        var name: TestSource = .{ .bytes = name_text };
        var arguments: TestSource = .{ .bytes = case.text };
        const offered: Offered = .{ .names = if (case.offered) name_text else "" };
        const facts = try inspectCall(&name, name_text.len, &arguments, &offered);
        try std.testing.expectEqual(case.rejected, classifyCall(&facts));
        if (case.rejected == null) {
            try std.testing.expectEqual(Runner.github_pr_watch, facts.tool.?.runner());
            try std.testing.expect(facts.label() == null and facts.subject() == null);
        }
    }
}
