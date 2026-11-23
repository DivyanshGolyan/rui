const std = @import("std");
const cli_args = @import("cli_args.zig");

// Finding F2: the catalog previously named a help owner that did not exist.
test "CLI-1 help is decided by argv alone" {
    for ([_]?bool{ null, false, true }) |exists| {
        for ([_][]const u8{ "--help", "-h" }) |flag| {
            try std.testing.expect(touchesNothing(next(.{ .args = &.{ "rui", flag }, .record_exists = exists }, std.testing.allocator)));
            try std.testing.expectEqual(.root_help, std.meta.activeTag(next(.{ .args = &.{ "rui", flag }, .record_exists = exists }, std.testing.allocator)));
            inline for (std.meta.tags(cli_args.Resource)) |resource| {
                const args = [_][]const u8{ "rui", @tagName(resource), flag };
                const route = next(.{ .args = &args, .record_exists = exists }, std.testing.allocator);
                try std.testing.expectEqual(.resource_help, std.meta.activeTag(route));
                try std.testing.expect(touchesNothing(route));
                const no_flag = next(.{ .args = &.{ "rui", @tagName(resource) }, .record_exists = exists }, std.testing.allocator);
                try std.testing.expectEqual(.resource_help, std.meta.activeTag(no_flag));
                try std.testing.expect(touchesNothing(no_flag));
            }
            inline for (std.meta.tags(cli_args.Command)) |command| {
                const definition = command.definition();
                const args = [_][]const u8{ "rui", @tagName(definition.resource), definition.name, flag };
                const route = next(.{ .args = &args, .record_exists = exists }, std.testing.allocator);
                try std.testing.expectEqual(.command_help, std.meta.activeTag(route));
                try std.testing.expect(touchesNothing(route));
                if (definition.optionNamed("record") != null) {
                    const record_args = [_][]const u8{ "rui", @tagName(definition.resource), definition.name, "--record", "capture", flag };
                    const record_route = next(.{ .args = &record_args, .record_exists = exists }, std.testing.allocator);
                    try std.testing.expectEqual(.command_help, std.meta.activeTag(record_route));
                    try std.testing.expect(touchesNothing(record_route));
                }
            }
        }
    }
    const help_cases = [_]struct { args: []const []const u8, fragments: []const []const u8 }{
        .{ .args = &.{ "rui", "session", "configure", "--help" }, .fragments = &.{ "rui session configure [", "Omission preserves", "default resets", "A model Rui does not list", "rui session inspect", "extra compaction headroom", "Changes apply to new model requests.", "Requests already accepted keep their original settings, even when retried." } },
        .{ .args = &.{ "rui", "session", "inspect", "--help" }, .fragments = &.{"rui session inspect ["} },
        .{ .args = &.{ "rui", "session", "send", "--help" }, .fragments = &.{ "rui session send [", "\nRequires: --to ID.\n", "stdin" } },
        .{ .args = &.{ "rui", "auth", "login", "--help" }, .fragments = &.{ "rui auth login [", "\nRequires: PROVIDER.\n" } },
    };
    for (help_cases) |case| {
        const route = next(.{ .args = case.args }, std.testing.allocator);
        try std.testing.expectEqual(.command_help, std.meta.activeTag(route));
        var storage: [32768]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&storage);
        try route.command_help.help(&writer);
        try std.testing.expect(std.mem.startsWith(u8, writer.buffered(), case.fragments[0]));
        for (case.fragments) |fragment| try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), fragment) != null);
    }
}

test "CLI-2 invalid invocation is refused before effects" {
    const Case = struct { args: []const []const u8, code: @import("caller_error.zig").Code, line: []const u8 };
    const cases = [_]Case{
        .{ .args = &.{ "rui", "session", "start", "--permission-mode", "auto" }, .code = .choice_unsupported, .line = "rui session start: --permission-mode auto: That value is not supported. Accepted: ask, bypass. Next: Use one of the accepted values. Nothing was captured or sent. [choice_unsupported]\n" },
        .{ .args = &.{ "rui", "request", "inspect", "HANDLE", "--store", "P" }, .code = .handle_names_store_and_key, .line = "rui request inspect: --store with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .args = &.{ "rui", "session", "interrupt-model", "--session", "k7m2qx", "--turn", "12x", "--operation", "3" }, .code = .id_malformed, .line = "rui session interrupt-model: --turn 12x: That is not an ID. Accepted: a decimal from 1 to 9223372036854775807. Next: Copy the ID from rui session inspect. Nothing was captured or sent. [id_malformed]\n" },
        .{ .args = &.{ "rui", "session", "configure", "--instructions", "file" }, .code = .instructions_source, .line = "rui session configure: --instructions file: Instructions must be read from stdin. Accepted: -. Next: Use --instructions - and pipe or redirect the instructions into this command. Nothing was captured or sent. [instructions_source]\n" },
        .{ .args = &.{ "rui", "session", "configure", "--instructions", "-", "--output-schema", "-" }, .code = .stdin_sources_conflict, .line = "rui session configure: --instructions with --output-schema: Instructions and the output schema cannot both read stdin. Accepted: --instructions - with --output-schema FILE, or --output-schema - without --instructions. Next: Read the schema from a file or supply instructions in a separate command. Nothing was captured or sent. [stdin_sources_conflict]\n" },
        .{ .args = &.{ "rui", "session", "send", "k7m2qx" }, .code = .session_id_needs_to, .line = "rui session send: k7m2qx: A positional Session ID is not a destination selector. Accepted: --to ID, with Message text on stdin. Next: Move the Session ID to --to ID and pipe or redirect the Message into stdin. Nothing was captured or sent. [session_id_needs_to]\n" },
        .{ .args = &.{ "rui", "session", "configure", "k7m2qx" }, .code = .session_id_needs_session, .line = "rui session configure: k7m2qx: A positional Session ID is not a Session selector for this command. Accepted: --session ID. Next: Move the Session ID to --session ID. Nothing was captured or sent. [session_id_needs_session]\n" },
        .{ .args = &.{ "rui", "session", "send", "--to", "k7m2qx", "literal" }, .code = .message_not_stdin, .line = "rui session send: literal: Message text must come from stdin, not positional arguments. Accepted: Message text on stdin, not in argv. Next: Pipe or redirect the Message into this command. Nothing was captured or sent. [message_not_stdin]\n" },
        .{ .args = &.{ "rui", "session", "list", "literal" }, .code = .positional_unexpected, .line = "rui session list: literal: That positional argument is not supported here. Accepted: options and values listed by rui session list --help. Next: Remove it and use this command's declared options and selectors. Nothing was captured or sent. [positional_unexpected]\n" },
    };
    for (cases) |case| {
        const route = next(.{ .args = case.args }, std.testing.allocator);
        try std.testing.expectEqual(.refused, std.meta.activeTag(route));
        try std.testing.expect(touchesNothing(route));
        try std.testing.expectEqual(case.code, route.refused.syntax.problem.code);
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writeRefusal(&writer, route.refused);
        try std.testing.expectEqualStrings(case.line, writer.buffered());
    }
    const unknown = [_]struct { args: []const []const u8, line: []const u8 }{
        .{ .args = &.{ "rui", "host", "stop" }, .line = "\nrui: unknown host operation; use rui host --help.\n" },
        .{ .args = &.{ "rui", "host", "missing" }, .line = "\nrui: unknown host operation; use rui host --help.\n" },
    };
    for (unknown) |case| {
        const route = next(.{ .args = case.args }, std.testing.allocator);
        try std.testing.expectEqual(.refused, std.meta.activeTag(route));
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writeRefusal(&writer, route.refused);
        try std.testing.expectEqualStrings(case.line, writer.buffered());
    }
    const missing_cases = [_]struct { args: []const []const u8, line: []const u8 }{
        .{ .args = &.{ "rui", "session", "send" }, .line = "rui session send: --to ID: A required option or selector is missing. Accepted: --to ID. Next: Supply one of the accepted alternatives. Nothing was captured or sent. [option_required]\n" },
        .{ .args = &.{ "rui", "session", "send", "--to", "k7m2qx", "--key", "half-key" }, .line = "rui session send: --record FILE: A required option or selector is missing. Accepted: --record FILE. Next: Supply one of the accepted alternatives. Nothing was captured or sent. [option_required]\n" },
        .{ .args = &.{ "rui", "session", "send", "--to", "k7m2qx", "--record", "/no/record" }, .line = "rui session send: --key KEY or --key-hex HEX: A required option or selector is missing. Accepted: --key KEY or --key-hex HEX. Next: Supply one of the accepted alternatives. Nothing was captured or sent. [option_required]\n" },
        .{ .args = &.{ "rui", "request", "recover", "--record", "/no/record", "--kind", "message" }, .line = "rui request recover: --store PATH or --store-hex HEX: A required option or selector is missing. Accepted: --store PATH or --store-hex HEX. Next: Supply one of the accepted alternatives. Nothing was captured or sent. [option_required]\n" },
        .{ .args = &.{ "rui", "auth", "login" }, .line = "rui auth login: PROVIDER: A required option or selector is missing. Accepted: PROVIDER. Next: Supply one of the accepted alternatives. Nothing was captured or sent. [option_required]\n" },
    };
    for (missing_cases) |case| {
        const route = next(.{ .args = case.args }, std.testing.allocator);
        try std.testing.expectEqual(.refused, std.meta.activeTag(route));
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writeRefusal(&writer, route.refused);
        try std.testing.expectEqualStrings(case.line, writer.buffered());
    }
    // A help-looking token used as an option value is not a help request.
    for ([_][]const []const u8{
        &.{ "rui", "session", "configure", "--model", "--help" },
        &.{ "rui", "session", "configure", "--session", "-h" },
    }) |argv| try std.testing.expectEqual(.dispatch, std.meta.activeTag(next(.{ .args = argv }, std.testing.allocator)));
    for ([_][]const []const u8{
        &.{ "rui", "session", "configure", "--compaction-trigger", "10", "--compaction-trigger", "20" },
        &.{ "rui", "session", "configure", "--output-reservation", "10", "--output-reservation", "20" },
    }) |argv| {
        const route = next(.{ .args = argv }, std.testing.allocator);
        try std.testing.expectEqual(.refused, std.meta.activeTag(route));
        try std.testing.expectEqual(.option_repeated, route.refused.syntax.problem.code);
    }
    const fresh_cases = [_]struct { args: []const []const u8, code: caller_error.Code, line: []const u8 }{
        .{ .args = &.{"--not-an-option"}, .code = .option_unknown, .line = "rui: --not-an-option: That option is not supported by this command. Accepted: options and values listed by rui --help. Next: Use an option listed by this command's help. Nothing was captured or sent. [option_unknown]\n" },
        .{ .args = &.{ "--", "setup" }, .code = .positional_unexpected, .line = "rui: setup: That positional argument is not supported here. Accepted: options and values listed by rui --help. Next: Remove it and use this command's declared options and selectors. Nothing was captured or sent. [positional_unexpected]\n" },
    };
    for (fresh_cases) |case| {
        var refusal: cli_args.Refusal = undefined;
        if (cli_args.fresh_session.parse(case.args, std.testing.allocator, &refusal)) |_| return error.ExpectedRefusal else |_| {}
        try std.testing.expectEqual(case.code, refusal.code);
        var buffer: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        try writeParseProblem(&writer, refusal, null, null, null);
        try std.testing.expectEqualStrings(case.line, writer.buffered());
    }
    const args = &[_][]const u8{ "rui", "session", "configure", "--record", "record", "--key", "k", "--permission-mode", "historical-mode" };
    const stat = next(.{ .args = args }, std.testing.allocator);
    try std.testing.expectEqual(.stat_record, std.meta.activeTag(stat));
    try std.testing.expectEqualStrings("record", stat.stat_record.path);
    const fresh = next(.{ .args = args, .record_exists = false }, std.testing.allocator);
    try std.testing.expectEqual(.refused, std.meta.activeTag(fresh));
    try std.testing.expectEqual(.choice_unsupported, fresh.refused.syntax.problem.code);
    const saved = next(.{ .args = args, .record_exists = true }, std.testing.allocator);
    try std.testing.expectEqual(.dispatch, std.meta.activeTag(saved));
    try std.testing.expectEqualStrings("historical-mode", saved.dispatch.parsed.get("permission-mode").?);
    var context_buffer: [1024]u8 = undefined;
    var context_writer: std.Io.Writer = .fixed(&context_buffer);
    try writeParseProblem(&context_writer, .{ .code = .instructions_source, .token = "instructions", .value = "file" }, null, "/setup", "; active Session unchanged");
    try std.testing.expectEqualStrings("rui /setup: --instructions file: Instructions must be read from stdin. Accepted: -. Next: Use --instructions - and pipe or redirect the instructions into this command. Nothing was captured or sent.; active Session unchanged [instructions_source]\n", context_writer.buffered());
}

const caller_error = @import("caller_error.zig");

pub const Facts = struct {
    args: []const []const u8,
    record_exists: ?bool = null,
};

pub const Refused = union(enum) {
    unknown_operation: cli_args.Resource,
    syntax: struct { resource: cli_args.Resource, operation: []const u8, problem: cli_args.Refusal },
    missing: struct { resource: cli_args.Resource, definition: cli_args.Definition, group: []const []const u8 },
};

pub const Route = union(enum) {
    host_coordinator,
    publish_install: []const []const u8,
    installation: enum { path, state, facts },
    upgrade: []const []const u8,
    root_help,
    version,
    resource_help: cli_args.Resource,
    command_help: cli_args.Definition,
    refused: Refused,
    stat_record: struct { path: []const u8, resource: cli_args.Resource, operation: []const u8 },
    new_session: []const []const u8,
    dispatch: struct { command: cli_args.Command, parsed: cli_args.Parsed },
};

pub fn touchesNothing(route: Route) bool {
    return switch (route) {
        .root_help, .version, .resource_help, .command_help, .refused => true,
        else => false,
    };
}

pub fn next(facts: Facts, allocator: std.mem.Allocator) Route {
    const args = facts.args;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--host-coordinator")) return .host_coordinator;
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) return .root_help;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) return .version;
    if (args.len >= 2 and std.mem.eql(u8, args[1], "upgrade")) return .{ .upgrade = args[2..] };
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--publish-install")) return .{ .publish_install = args[2..] };
    if (args.len == 2 and std.mem.eql(u8, args[1], "--installation-path")) return .{ .installation = .path };
    if (args.len == 2 and std.mem.eql(u8, args[1], "--installation-path-state")) return .{ .installation = .state };
    if (args.len == 2 and std.mem.eql(u8, args[1], "--installation-facts")) return .{ .installation = .facts };
    if (args.len < 2 or std.mem.startsWith(u8, args[1], "--")) return .{ .new_session = args[1..] };
    const resource = std.meta.stringToEnum(cli_args.Resource, args[1]) orelse return .{ .new_session = args[1..] };
    if (args.len == 2 or (args.len == 3 and (std.mem.eql(u8, args[2], "--help") or std.mem.eql(u8, args[2], "-h")))) return .{ .resource_help = resource };
    const command = cli_args.find(resource, args[2]) orelse return .{ .refused = .{ .unknown_operation = resource } };
    const definition = command.definition();
    var problem: cli_args.Refusal = undefined;
    const parsed = definition.parseSyntax(args[3..], allocator, &problem) catch return .{ .refused = .{ .syntax = .{ .resource = resource, .operation = definition.name, .problem = problem } } };
    if (parsed.help) return .{ .command_help = definition };
    if (parsed.missing()) |group| return .{ .refused = .{ .missing = .{ .resource = resource, .definition = definition, .group = group } } };
    if (definition.mutation and !std.mem.eql(u8, definition.name, "recover")) {
        if (parsed.get("record")) |record| {
            if (facts.record_exists == null) return .{ .stat_record = .{ .path = record, .resource = resource, .operation = definition.name } };
            if (facts.record_exists.?) return .{ .dispatch = .{ .command = command, .parsed = parsed } };
        }
    }
    parsed.validateValues(&problem) catch return .{ .refused = .{ .syntax = .{ .resource = resource, .operation = definition.name, .problem = problem } } };
    return .{ .dispatch = .{ .command = command, .parsed = parsed } };
}

pub fn writeParseProblem(writer: *std.Io.Writer, problem: cli_args.Refusal, resource: ?[]const u8, operation: ?[]const u8, unchanged: ?[]const u8) !void {
    var held = problem.held(resource, operation);
    held.unchanged = unchanged;
    try caller_error.writeLine(writer, problem.code, held);
}

pub fn writeRefusal(writer: *std.Io.Writer, refused: Refused) !void {
    switch (refused) {
        .unknown_operation => |resource| try writer.print("\nrui: unknown {s} operation; use rui {s} --help.\n", .{ @tagName(resource), @tagName(resource) }),
        .syntax => |s| try writeParseProblem(writer, s.problem, @tagName(s.resource), s.operation, null),
        .missing => |m| {
            var buffer: [1024]u8 = undefined;
            var group: std.Io.Writer = .fixed(&buffer);
            try m.definition.writeGroup(&group, m.group);
            const problem: cli_args.Refusal = .{ .code = .option_required, .token = group.buffered(), .option = false, .accepted = .{ .grammar = group.buffered() } };
            try writeParseProblem(writer, problem, @tagName(m.resource), m.definition.name, null);
        },
    }
}
