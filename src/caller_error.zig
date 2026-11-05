//! CLI causes and their repair contract. No wire or Store policy.
//! Saved-code facts are replay-affecting: do not reinterpret them using live state.
const std = @import("std");
const TerminalText = @import("TerminalText.zig");
const provider_name = @import("provider_name.zig");
const cli_value = @import("cli_value.zig");

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
    rejection_unrecognized,
    // Existing saved wire spellings; PR 5 owns splitting and renaming them.
    invalid_session_reference,
    unknown_session,
    invalid_sender_handle,
    unsupported_permission_mode,
    unsupported_provider,
    invalid_model,
    model_capability_unavailable,
    invalid_output_schema,
    invalid_compaction_trigger,
    compact_at_too_large,
    invalid_output_reservation,
    unsupported_reasoning_effort,
    unknown_tool,
    provider_tool_missing,
    loaded_tools_not_in_tools,
    loaded_tools_unreachable,
    invalid_label,
    incomplete_initial_configuration,
    invalid_workspace,
    workspace_is_immutable,
    provider_is_immutable,
    model_is_immutable,
    revision_exhausted,
    invalid_target,
    unknown_operation,
    target_mismatch,
    operation_resolved,
    unknown_action,
    action_not_pending,
    invalid_arguments,
    idempotency_key_conflict,
    host_busy,
    result_not_ready,
    host_stopped,
    host_unreachable,
    sign_in_required,
    store_locked,
    reply_unconfirmed,
};

pub const Act = enum { fix, wait, operate, recover, report };
pub const Remedy = Act;
pub const Input = enum {
    option,
    positional,
    instructions,
    identity,
    stdin,
    session,
    sender_handle,
    permission_mode,
    provider,
    model,
    output_schema,
    compaction_trigger,
    output_reservation,
    reasoning_effort,
    tools,
    loaded_tools,
    label,
    initial_configuration,
    workspace,
    target,
    operation,
    action,
    arguments,
    key,

    fn spelling(self: Input) ?[]const u8 {
        return switch (self) {
            .session => "--session / --to",
            .sender_handle => "RUI_SENDER_HANDLE",
            .permission_mode => "--permission-mode",
            .provider => "--provider",
            .model => "--model",
            .output_schema => "--output-schema",
            .compaction_trigger => "--compaction-trigger",
            .output_reservation => "--output-reservation",
            .reasoning_effort => "--reasoning-effort",
            .tools => "--tools",
            .loaded_tools => "--loaded-tools",
            .label => "--label",
            .initial_configuration => "--workspace, --provider, --model",
            .workspace => "--workspace",
            .target => "--turn / --operation / --action",
            .operation => "--operation",
            .action => "--action",
            .arguments => "arguments",
            .key => "--key",
            else => null,
        };
    }
};
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
        .invalid_session_reference => .{ .act = .fix, .input = .session, .accepted = .{ .grammar = "six lowercase Crockford characters, for example k7m2qx" }, .says = "That Session reference is malformed.", .next = "Copy the Session ID from rui session list." },
        .unknown_session => .{ .act = .fix, .input = .session, .accepted = .{ .grammar = "an existing Session ID from rui session list" }, .says = "No Session with this ID exists in this Store.", .next = "Select the right --store and an ID from rui session list, or create a Session with rui session start." },
        .invalid_sender_handle => .{ .act = .fix, .input = .sender_handle, .accepted = .{ .grammar = "the live peer context supplied by Rui" }, .says = "The peer sender handle is invalid or no longer live.", .next = "Send from a live Rui Session; do not fabricate or reuse peer environment variables." },
        .unsupported_permission_mode => .{ .act = .fix, .input = .permission_mode, .accepted = .{ .closed = names(cli_value.PermissionMode) }, .says = "Rui has no such permission mode.", .next = "Use one of the accepted values." },
        .unsupported_provider => .{ .act = .fix, .input = .provider, .accepted = .{ .closed = names(provider_name.Provider) }, .says = "Rui has no such provider.", .next = "Use one of the accepted providers." },
        .invalid_model => .{ .act = .fix, .input = .model, .accepted = .{ .grammar = "a nonempty model ID; see rui session configure --help for syntax and suggested IDs" }, .says = "The model ID is empty.", .next = "Supply a nonempty --model; unlisted IDs are allowed and use default limits." },
        .model_capability_unavailable => .{ .act = .fix, .input = .provider, .accepted = .{ .grammar = "a provider served by this Host; see rui host status" }, .says = "This Host does not serve the Session's required provider.", .next = "Use a Host serving --provider, or create a Session with a provider listed by rui host status." },
        .invalid_output_schema => .{ .act = .fix, .input = .output_schema, .accepted = .{ .grammar = "a file containing valid JSON for the provider's output schema" }, .says = "The output schema is not valid JSON.", .next = "Fix the JSON in --output-schema FILE, or omit the schema." },
        .invalid_compaction_trigger => .{ .act = .fix, .input = .compaction_trigger, .accepted = .{ .grammar = "default or a decimal from 1 to " ++ std.fmt.comptimePrint("{d}", .{std.math.maxInt(i64)}) }, .says = "The compaction trigger is not a positive token count.", .next = "Use --compaction-trigger default or a positive decimal in the accepted range." },
        .compact_at_too_large => .{ .act = .fix, .input = .compaction_trigger, .accepted = .{ .grammar = "a token count no larger than the model's context window" }, .says = "The compaction trigger is larger than the model's context window.", .next = "Use --compaction-trigger default, or a smaller token count." },
        .invalid_output_reservation => .{ .act = .fix, .input = .output_reservation, .accepted = .{ .grammar = "default or a decimal from 0 to " ++ std.fmt.comptimePrint("{d}", .{std.math.maxInt(i64)}) }, .says = "The output reservation is not a nonnegative token count.", .next = "Use --output-reservation default or a nonnegative decimal in the accepted range." },
        .unsupported_reasoning_effort => .{ .act = .fix, .input = .reasoning_effort, .accepted = .{ .closed = names(cli_value.ReasoningChoice) }, .says = "The reasoning effort is unknown or unsupported by this model.", .next = "Use --reasoning-effort default, or select a listed effort supported by the saved model." },
        .unknown_tool => .{ .act = .fix, .input = .tools, .accepted = .{ .grammar = "built-in tools listed by rui session configure --help, or tools offered by this Host" }, .says = "A requested tool is not offered by this Host.", .next = "Check --tools against the Host's offered tools, or use --tools none." },
        .provider_tool_missing => .{ .act = .fix, .input = .tools, .accepted = .{ .grammar = "tools offered by this Host and supported by the selected provider" }, .says = "The selected provider cannot run a requested tool.", .next = "Remove the unsupported tool from --tools, or create a Session with a provider that supports it." },
        .loaded_tools_not_in_tools => .{ .act = .fix, .input = .loaded_tools, .accepted = .{ .grammar = "a subset of the Session's --tools, or none" }, .says = "A loaded tool is not one of the Session's tools.", .next = "Remove it from --loaded-tools, or add it to --tools first." },
        .loaded_tools_unreachable => .{ .act = .fix, .input = .loaded_tools, .accepted = .{ .grammar = "every tool in --tools, or a subset when find_tools is loaded" }, .says = "Some tools would never be reachable: --loaded-tools leaves tools out without loading find_tools.", .next = "Add find_tools to --loaded-tools, or load every tool in --tools." },
        .invalid_label => .{ .act = .fix, .input = .label, .accepted = .{ .grammar = "one line of at most 100 UTF-8 bytes, or an empty string to clear it" }, .says = "The Label is too long or contains a line break or control character.", .next = "Shorten --label and remove line breaks and control characters." },
        .incomplete_initial_configuration => .{ .act = .fix, .input = .initial_configuration, .accepted = .{ .grammar = "model, reasoning effort, compaction trigger, tools and permission mode, a workspace when tools include bash, and a provider when the Host serves several" }, .says = "A new Session's spec is missing a required setting.", .next = "State every required setting; rui session start fills them for you." },
        .invalid_workspace => .{ .act = .fix, .input = .workspace, .accepted = .{ .grammar = "an absolute path to an existing directory" }, .says = "The workspace is not a usable absolute directory.", .next = "Set --workspace to an existing absolute directory accessible to the Host." },
        .workspace_is_immutable => .{ .act = .fix, .input = .workspace, .accepted = .{ .grammar = "the workspace already saved for this Session" }, .says = "An existing Session cannot change its workspace.", .next = "Omit --workspace, or create a new Session for the other directory." },
        .provider_is_immutable => .{ .act = .fix, .input = .provider, .accepted = .{ .grammar = "the provider already saved for this Session" }, .says = "An existing Session cannot change its provider.", .next = "Omit --provider, or create a new Session with the other provider." },
        .model_is_immutable => .{ .act = .fix, .input = .model, .accepted = .{ .grammar = "the model already saved for this Session" }, .says = "An existing Session cannot change its model.", .next = "Omit --model, or create a new Session with the other model." },
        .revision_exhausted => .{ .act = .fix, .input = .session, .accepted = .{ .grammar = "a Session whose configuration revision can still advance" }, .says = "This Session has exhausted its configuration revisions.", .next = "Create a new Session with the desired configuration." },
        .invalid_target => .{ .act = .fix, .input = .target, .accepted = .{ .grammar = "positive decimal IDs from 1 to 9223372036854775807 for the requested target" }, .says = "A target ID is invalid.", .next = "Copy --turn and --operation for interruption, or --action for a decision, from rui session inspect." },
        .unknown_operation => .{ .act = .fix, .input = .operation, .accepted = .{ .grammar = "an Operation ID belonging to this Session, from rui session inspect" }, .says = "That Operation does not exist in this Session.", .next = "Inspect this Session and use its current --turn and --operation." },
        .target_mismatch => .{ .act = .fix, .input = .target, .accepted = .{ .grammar = "IDs identifying the same saved target in the selected Session" }, .says = "The target IDs do not identify the requested work in this Session.", .next = "Copy the matching Session and target IDs from rui session inspect." },
        .operation_resolved => .{ .act = .fix, .input = .operation, .accepted = .{ .grammar = "a currently unresolved Operation in this Session" }, .says = "That Operation has already resolved.", .next = "Inspect this Session; interrupt only an Operation that is still running." },
        .unknown_action => .{ .act = .fix, .input = .action, .accepted = .{ .grammar = "an Action ID belonging to this Session, from rui session inspect" }, .says = "That Action does not exist in this Session.", .next = "Select the Session and pending --action shown by rui session inspect." },
        .action_not_pending => .{ .act = .fix, .input = .action, .accepted = .{ .grammar = "an Action currently awaiting permission in this Session" }, .says = "That Action is not awaiting a permission decision.", .next = "Inspect this Session and decide only an Action currently awaiting permission." },
        .invalid_arguments => .{ .act = .fix, .input = .arguments, .accepted = .{ .grammar = "arguments satisfying the selected tool schema" }, .says = "The tool arguments are invalid.", .next = "Correct the arguments to match the selected tool schema." },
        .idempotency_key_conflict => .{ .act = .fix, .input = .key, .accepted = .{ .grammar = "one immutable captured request per key" }, .says = "This key already belongs to a different request.", .next = "Recover the original capture to inspect it; use a new key only for intentionally different work." },
        .host_busy => .{ .act = .wait, .input = null, .accepted = .none, .says = "The Host is busy.", .next = "Retry the same request unchanged later." },
        .result_not_ready => .{ .act = .wait, .input = null, .accepted = .none, .says = "The saved result is not ready yet.", .next = "Run the same rui request read-result command again later." },
        .host_stopped => .{ .act = .operate, .input = null, .accepted = .none, .says = "The Host is stopped.", .next = "Start this Store's Host with rui host start, then retry unchanged." },
        .host_unreachable => .{ .act = .operate, .input = null, .accepted = .none, .says = "The Host cannot be reached.", .next = "Start or repair this Store's Host, then retry the same saved request unchanged." },
        .sign_in_required => .{ .act = .operate, .input = null, .accepted = .none, .says = "Provider sign-in is required.", .next = "Run rui auth login for the selected provider, then retry unchanged." },
        .store_locked => .{ .act = .operate, .input = null, .accepted = .none, .says = "Another Host owns this Store.", .next = "Use that Host, or pause it with rui host pause before starting again." },
        .reply_unconfirmed => .{ .act = .recover, .input = null, .accepted = .none, .says = "Admission is not confirmed.", .next = "Run rui request recover with the original HANDLE or record; never resubmit with a new key." },
        .memory_exhausted => .{ .act = .operate, .input = null, .accepted = .none, .says = "Memory was exhausted while reading the arguments.", .next = "Free memory and try the same invocation again." },
        .rejection_unrecognized => .{ .act = .report, .input = null, .accepted = .none, .says = "Rui saved a rejection whose code this rui build does not know; the code is in the JSON answer on stdout.", .next = "Use a rui build that matches the Host, then recover the same saved request to read it." },
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
    return renderLine(out, code, held, false);
}

/// No current argv/accepted override: replay renders the saved rejection facts.
pub fn writeSavedLine(out: *std.Io.Writer, code: Code, held: Held) error{WriteFailed}!void {
    return renderLine(out, code, .{ .resource = held.resource, .operation = held.operation }, true);
}

fn renderLine(out: *std.Io.Writer, code: Code, held: Held, saved: bool) error{WriteFailed}!void {
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
    if (saved) if (f.input) |input| if (input.spelling()) |spelling| {
        try out.writeAll(spelling);
        try out.writeAll(": ");
    };
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
    try out.print(" Next: {s}", .{f.next});
    try out.writeAll(if (saved) " This rejection was saved and replays as saved; a resend needs a new key." else " Nothing was captured or sent.");
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
        if (facts(code).accepted != .none) try std.testing.expect(std.mem.indexOf(u8, line, " Accepted: ") != null);
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

test "saved rejection facts ignore current rendering overrides" {
    inline for (comptime std.meta.tags(Code)) |code| {
        var storage: [2048]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        try writeSavedLine(&out, code, .{ .resource = "session", .operation = "configure", .spelling = "today", .value = "do not use", .accepted = .{ .closed = &.{"live-policy"} } });
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "today") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "live-policy") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "Nothing was captured or sent") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "replays as saved; a resend needs a new key.") != null);
    }
}

test "saved ambiguous causes do not invent missing flags or model restrictions" {
    const initial = facts(.incomplete_initial_configuration);
    try std.testing.expectEqualStrings("model, reasoning effort, compaction trigger, tools and permission mode, a workspace when tools include bash, and a provider when the Host serves several", initial.accepted.grammar);
    try std.testing.expectEqualStrings("A new Session's spec is missing a required setting.", initial.says);
    try std.testing.expectEqualStrings("The model ID is empty.", facts(.invalid_model).says);
    try std.testing.expectEqual(Input.provider, facts(.model_capability_unavailable).input.?);
    try std.testing.expectEqualStrings("default or a decimal from 1 to 9223372036854775807", facts(.invalid_compaction_trigger).accepted.grammar);
    try std.testing.expectEqualStrings("default or a decimal from 0 to 9223372036854775807", facts(.invalid_output_reservation).accepted.grammar);
    try std.testing.expectEqualSlices([]const u8, names(cli_value.PermissionMode), facts(.unsupported_permission_mode).accepted.closed);
    try std.testing.expectEqualSlices([]const u8, names(cli_value.ReasoningChoice), facts(.unsupported_reasoning_effort).accepted.closed);
}
