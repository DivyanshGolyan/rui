//! CLI invocation causes and their repair contract. No wire or Store policy.
const std = @import("std");
const TerminalText = @import("TerminalText.zig");

pub const Code = enum {
    option_unknown,
    option_repeated,
    option_repeat_limit,
    option_value_missing,
    option_required,
    positional_unexpected,
    message_not_stdin,
    hex_malformed,
    id_malformed,
    count_malformed,
    choice_unsupported,
    instructions_source,
    handle_names_store_and_key,
    handle_names_store_record_and_kind,
    session_selector_repeated,
    output_schema_excludes_text_output,
    profile_excludes_failed_response,
    all_excludes_session,
    all_excludes_record,
    all_excludes_key,
    model_excludes_clear_model,
    launch_frame_excludes_store,
    launch_frame_excludes_provider,
    launch_frame_excludes_provider_endpoint,
    launch_frame_excludes_provider_ca_file,
    launch_frame_excludes_active_capacity,
    launch_frame_excludes_codex_fixture,
    launch_frame_excludes_openai_fixture,
    provider_excludes_endpoint,
    provider_excludes_ca_file,
    provider_excludes_codex_fixture,
    codex_fixture_excludes_endpoint,
    openai_fixture_excludes_endpoint,
    identity_spelling_repeated,
    stdin_sources_conflict,
    memory_exhausted,
};

pub const Remedy = enum { fix, operate };
pub const Input = enum { option, positional, instructions, identity, stdin };
pub const Read = enum { command_help };
pub const Accepted = union(enum) {
    closed: []const []const u8,
    grammar: []const u8,
    read: Read,
    none,
};

/// No defaults: every cause must declare all its static facts.
pub const Facts = struct {
    act: Remedy,
    input: ?Input,
    accepted: Accepted,
    says: []const u8,
    next: []const u8,
};

pub fn facts(code: Code) Facts {
    return switch (code) {
        .option_unknown => .{ .act = .fix, .input = .option, .accepted = .{ .read = .command_help }, .says = "That option is not supported by this command.", .next = "Use an option listed by this command's help." },
        .option_repeated => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "one occurrence of this option" }, .says = "That option was given more than once.", .next = "Keep one occurrence." },
        .option_repeat_limit => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "at most 16 repeated option values in total" }, .says = "The invocation exceeds the repeat limit.", .next = "Remove repeated values until the invocation fits the limit." },
        .option_value_missing => .{ .act = .fix, .input = .option, .accepted = .{ .read = .command_help }, .says = "That option needs a value.", .next = "Put an accepted value immediately after the flag." },
        .option_required => .{ .act = .fix, .input = .option, .accepted = .{ .read = .command_help }, .says = "A required option or selector is missing.", .next = "Supply one of the accepted alternatives." },
        .positional_unexpected => .{ .act = .fix, .input = .positional, .accepted = .{ .read = .command_help }, .says = "That positional argument is not supported here.", .next = "Remove it and use this command's declared options and selectors." },
        .message_not_stdin => .{ .act = .fix, .input = .stdin, .accepted = .{ .grammar = "Message text on stdin, not in argv" }, .says = "Message text must come from stdin, not positional arguments.", .next = "Pipe or redirect the Message into this command." },
        .hex_malformed => .{ .act = .fix, .input = .identity, .accepted = .{ .grammar = "nonempty even-length hex encoding valid UTF-8 within the option byte limit" }, .says = "That identity is not valid hex.", .next = "Encode the identity's UTF-8 bytes as two hex digits per byte within the stated bound." },
        .id_malformed => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "a decimal from 1 to 9223372036854775807" }, .says = "That is not an ID.", .next = "Copy the ID from rui session inspect." },
        .count_malformed => .{ .act = .fix, .input = .option, .accepted = .{ .read = .command_help }, .says = "That is not a count in the accepted range.", .next = "Supply a decimal within the stated range, without signs or separators." },
        .choice_unsupported => .{ .act = .fix, .input = .option, .accepted = .{ .read = .command_help }, .says = "That value is not supported.", .next = "Use one of the accepted values." },
        .instructions_source => .{ .act = .fix, .input = .instructions, .accepted = .{ .closed = &.{"-"} }, .says = "Instructions must be read from stdin.", .next = "Use --instructions - and pipe or redirect the instructions into this command." },
        .handle_names_store_and_key => .{ .act = .fix, .input = .identity, .accepted = .{ .grammar = "HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX)" }, .says = "A saved HANDLE already names its Store and key.", .next = "Keep one of the two." },
        .handle_names_store_record_and_kind => .{ .act = .fix, .input = .identity, .accepted = .{ .grammar = "HANDLE alone, or (--store PATH or --store-hex HEX) with --record FILE --kind KIND" }, .says = "A saved HANDLE already names its Store, record and kind.", .next = "Keep one of the two." },
        .session_selector_repeated => .{ .act = .fix, .input = .identity, .accepted = .{ .grammar = "ID alone, or --session ID" }, .says = "The positional ID already names the Session.", .next = "Keep one Session selector." },
        .output_schema_excludes_text_output => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "--output-schema FILE or --text-output, not both" }, .says = "A schema and plain text output are alternative output modes.", .next = "Keep the desired output mode only." },
        .profile_excludes_failed_response => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "--profile PROFILE or --failed-response PART, not both" }, .says = "A Session report and a failed-response export are different inspections.", .next = "Keep one inspection mode." },
        .all_excludes_session => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "--all or --session ID, not both" }, .says = "Stopping all Sessions excludes a single Session selector.", .next = "Keep --all or select one Session." },
        .all_excludes_record => .{ .act = .fix, .input = .identity, .accepted = .{ .grammar = "--all without --record, or --session ID with an explicit capture" }, .says = "Stopping all Sessions creates a separate capture for each Session.", .next = "Remove --record or stop a single Session." },
        .all_excludes_key => .{ .act = .fix, .input = .identity, .accepted = .{ .grammar = "--all without --key or --key-hex, or --session ID with an explicit capture" }, .says = "Stopping all Sessions creates a separate key for each Session.", .next = "Remove the explicit key or stop a single Session." },
        .model_excludes_clear_model => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "--model MODEL or --clear-model, not both" }, .says = "Setting and clearing the saved model conflict.", .next = "Keep the desired model change only." },
        .launch_frame_excludes_store => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "--launch-frame, or --store PATH or --store-hex HEX without --launch-frame" }, .says = "The launch frame already supplies the Store.", .next = "Remove the Store flag or stop using --launch-frame." },
        .launch_frame_excludes_provider => launchConflict("provider", "--provider"),
        .launch_frame_excludes_provider_endpoint => launchConflict("provider endpoint", "--provider-endpoint"),
        .launch_frame_excludes_provider_ca_file => launchConflict("provider CA file", "--provider-ca-file"),
        .launch_frame_excludes_active_capacity => launchConflict("active capacity", "--active-capacity"),
        .launch_frame_excludes_codex_fixture => launchConflict("Codex fixture endpoint", "--test-codex-fixture-endpoint"),
        .launch_frame_excludes_openai_fixture => launchConflict("OpenAI fixture endpoint", "--test-openai-fixture-endpoint"),
        .provider_excludes_endpoint => endpointConflict("--provider-endpoint", "A managed provider and a development endpoint are alternative provider sources."),
        .provider_excludes_ca_file => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "--provider LABEL, or --provider-endpoint URL with --provider-ca-file PATH" }, .says = "A managed provider cannot use a development endpoint CA file.", .next = "Keep the managed provider or the development endpoint and its CA file." },
        .provider_excludes_codex_fixture => endpointConflict("--test-codex-fixture-endpoint", "A managed provider and a Codex fixture are alternative provider sources."),
        .codex_fixture_excludes_endpoint => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "--test-codex-fixture-endpoint URL or --provider-endpoint URL, not both" }, .says = "A Codex fixture and a development endpoint are alternative provider sources.", .next = "Keep one endpoint source." },
        .openai_fixture_excludes_endpoint => .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "--test-openai-fixture-endpoint URL or --provider-endpoint URL, not both" }, .says = "An OpenAI fixture and a development endpoint are alternative provider sources.", .next = "Keep one endpoint source." },
        .identity_spelling_repeated => .{ .act = .fix, .input = .identity, .accepted = .{ .grammar = "one spelling of the identity, plain or hex" }, .says = "Both spellings name the same identity.", .next = "Keep the plain flag or its hex spelling, not both." },
        .stdin_sources_conflict => .{ .act = .fix, .input = .stdin, .accepted = .{ .grammar = "--instructions - with --output-schema FILE, or --output-schema - without --instructions" }, .says = "Instructions and the output schema cannot both read stdin.", .next = "Read the schema from a file or supply instructions in a separate command." },
        .memory_exhausted => .{ .act = .operate, .input = null, .accepted = .none, .says = "Memory was exhausted while reading the arguments.", .next = "Free memory and try the same invocation again." },
    };
}

fn launchConflict(comptime field: []const u8, comptime flag: []const u8) Facts {
    return .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "--launch-frame without " ++ flag ++ ", or " ++ flag ++ " without --launch-frame" }, .says = "A launch frame cannot be combined with a separate " ++ field ++ " option.", .next = "Remove " ++ flag ++ " or stop using --launch-frame." };
}
fn endpointConflict(comptime flag: []const u8, comptime says: []const u8) Facts {
    return .{ .act = .fix, .input = .option, .accepted = .{ .grammar = "--provider LABEL or " ++ flag ++ " URL, not both" }, .says = says, .next = "Keep the managed provider or the development source, not both." };
}

pub fn names(comptime E: type) []const []const u8 {
    return @typeInfo(E).@"enum".field_names;
}

comptime {
    @setEvalBranchQuota(100_000);
    for (names(Code)) |tag| {
        const f = facts(@field(Code, tag));
        if (f.act == .fix and (f.input == null or f.accepted == .none)) @compileError(tag ++ " needs an input and accepted values");
        for (.{ f.says, f.next }) |sentence| {
            if (sentence.len == 0 or sentence.len > 200 or std.mem.indexOfAny(u8, sentence, "\r\n{") != null)
                @compileError(tag ++ " needs one-line sentences of at most 200 bytes");
            if (sentence[sentence.len - 1] != '.') @compileError(tag ++ " needs a complete sentence");
        }
    }
}

pub const Held = struct {
    resource: ?[]const u8 = null,
    operation: ?[]const u8 = null,
    spelling: ?[]const u8 = null,
    value: ?[]const u8 = null,
    other: ?[]const u8 = null,
    option: bool = true,
    accepted: ?Accepted = null,
    unchanged: ?[]const u8 = null,
};

/// Display copies are bounded; the parser's original argv is never changed.
/// Truncate at UTF-8 boundaries, then let the common terminal escaper render
/// controls/invalid UTF-8. 96 input bytes cost at most 384 output bytes.
fn writeHeld(out: *std.Io.Writer, text: []const u8) error{WriteFailed}!void {
    const bound = 96;
    var end = @min(text.len, bound);
    if (end < text.len) while (end > 0 and text[end] & 0xc0 == 0x80) : (end -= 1) {};
    var safe: TerminalText = .{ .mode = .line };
    // TerminalText's internal fixed hexadecimal buffers always fit their
    // two/four digit escapes; only the supplied writer can fail here.
    safe.feed(out, text[0..end]) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        error.NoSpaceLeft => unreachable,
    };
    safe.finish(out) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        error.NoSpaceLeft => unreachable,
    };
    if (end != text.len) try out.writeAll("...");
}

fn writeHelp(out: *std.Io.Writer, held: Held) error{WriteFailed}!void {
    try out.writeAll("rui");
    if (held.resource) |resource| {
        try out.writeByte(' ');
        try writeHeld(out, resource);
    }
    if (held.operation) |operation| {
        try out.writeByte(' ');
        try writeHeld(out, operation);
    }
    try out.writeAll(" --help");
}

pub fn writeLine(out: *std.Io.Writer, code: Code, held: Held) error{WriteFailed}!void {
    const f = facts(code);
    try out.writeAll("rui");
    if (held.resource) |resource| {
        try out.writeByte(' ');
        try writeHeld(out, resource);
    }
    if (held.operation) |operation| {
        try out.writeByte(' ');
        try writeHeld(out, operation);
    }
    try out.writeAll(": ");
    if (held.spelling) |spelling| {
        if (held.option) try out.writeAll("--");
        try writeHeld(out, spelling);
        if (held.value) |value| {
            try out.writeByte(' ');
            try writeHeld(out, value);
        }
        if (held.other) |other| {
            try out.writeAll(" with ");
            if (!std.mem.eql(u8, other, "HANDLE") and !std.mem.eql(u8, other, "ID") and !std.mem.startsWith(u8, other, "--")) try out.writeAll("--");
            try writeHeld(out, other);
        }
        try out.writeAll(": ");
    }
    try out.writeAll(f.says);
    switch (held.accepted orelse f.accepted) {
        .none => {},
        .grammar => |grammar| try out.print(" Accepted: {s}.", .{grammar}),
        .closed => |set| {
            try out.writeAll(" Accepted: ");
            for (set, 0..) |value, i| {
                if (i != 0) try out.writeAll(", ");
                try out.writeAll(value);
            }
            try out.writeByte('.');
        },
        .read => |read| switch (read) {
            .command_help => {
                try out.writeAll(" Accepted: options and values listed by ");
                try writeHelp(out, held);
                try out.writeByte('.');
            },
        },
    }
    try out.print(" Next: {s} Nothing was captured or sent.", .{f.next});
    if (held.unchanged) |unchanged| try writeHeld(out, unchanged);
    try out.print(" [{s}]\n", .{@tagName(code)});
}

test "caller error goldens describe choice handle conflict and malformed ID" {
    const Case = struct { code: Code, held: Held, expected: []const u8 };
    const cases = [_]Case{
        .{ .code = .choice_unsupported, .held = .{ .resource = "session", .operation = "start", .spelling = "permission-mode", .value = "auto", .accepted = .{ .closed = &.{ "ask", "bypass" } } }, .expected = "rui session start: --permission-mode auto: That value is not supported. Accepted: ask, bypass. Next: Use one of the accepted values. Nothing was captured or sent. [choice_unsupported]\n" },
        .{ .code = .handle_names_store_and_key, .held = .{ .resource = "request", .operation = "inspect", .spelling = "store", .other = "HANDLE" }, .expected = "rui request inspect: --store with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .code = .id_malformed, .held = .{ .resource = "session", .operation = "interrupt-model", .spelling = "turn", .value = "12x" }, .expected = "rui session interrupt-model: --turn 12x: That is not an ID. Accepted: a decimal from 1 to 9223372036854775807. Next: Copy the ID from rui session inspect. Nothing was captured or sent. [id_malformed]\n" },
    };
    for (cases) |case| {
        var storage: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        try writeLine(&out, case.code, case.held);
        try std.testing.expectEqualStrings(case.expected, out.buffered());
    }
}

test "every caller error code renders accepted facts and a concrete next step" {
    inline for (comptime std.meta.tags(Code)) |code| {
        var storage: [2048]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        try writeLine(&out, code, .{ .resource = "session", .operation = "configure", .spelling = "test" });
        const line = out.buffered();
        try std.testing.expect(std.mem.startsWith(u8, line, "rui session configure: --test: "));
        if (code != .memory_exhausted) try std.testing.expect(std.mem.indexOf(u8, line, " Accepted: ") != null);
        try std.testing.expect(std.mem.indexOf(u8, line, " Next: ") != null);
        try std.testing.expect(std.mem.endsWith(u8, line, "Nothing was captured or sent. [" ++ @tagName(code) ++ "]\n"));
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    }
    try std.testing.expectEqualStrings("option_unknown", names(Code)[0]);
}

test "caller error display escapes controls and truncates only complete UTF-8" {
    const hostile = "bad\x1b[31m\n\r\xff\"\\\u{202e}";
    var storage: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&storage);
    try writeLine(&out, .choice_unsupported, .{ .resource = "session", .operation = "start", .spelling = "permission-mode", .value = hostile, .accepted = .{ .closed = &.{ "ask", "bypass" } } });
    const line = out.buffered();
    try std.testing.expect(std.mem.indexOf(u8, line, "bad\\x1b[31m\\n\\r\\xff\\\"\\\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\x1b") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\u{202e}") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
    const long = @as([95]u8, @splat('a')) ++ "雪" ++ @as([4096]u8, @splat('b'));
    out = .fixed(&storage);
    try writeLine(&out, .choice_unsupported, .{ .spelling = "permission-mode", .value = long, .accepted = .{ .closed = &.{ "ask", "bypass" } } });
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "...: That value is not supported. Accepted: ask, bypass.") != null);
    try std.testing.expect(std.unicode.utf8ValidateSlice(out.buffered()));
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Nothing was captured or sent.") != null);
}

test "caller error renderer propagates a bounded writer failure" {
    var bytes: [1]u8 = undefined;
    var out = std.Io.Writer.fixed(&bytes);
    try std.testing.expectError(error.WriteFailed, writeLine(&out, .option_unknown, .{ .spelling = "bad" }));
}
