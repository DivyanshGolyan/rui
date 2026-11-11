//! Installed command grammar. Help and pre-effect syntax validation use the
//! same definitions; model/state-dependent values remain with the Store.
const std = @import("std");
const session_settings = @import("session_settings.zig");
const model_capability = @import("model_capability.zig");
const product_defaults = @import("product_defaults.zig");
const caller_error = @import("caller_error.zig");
const cli_value = @import("cli_value.zig");
const provider_name = @import("provider_name.zig");
const retention_capacity = @import("retention_capacity.zig");

const cli_grammar = @import("cli_grammar.zig");
const serve_grammar = @import("serve_grammar.zig");
const option_manifest = @import("cli_option_names.zig");
pub const Resource = cli_grammar.Resource;
pub const Refusal = cli_grammar.Refusal;
pub const Definition = cli_grammar.Definition;
pub const Parsed = cli_grammar.Parsed;
const Option = cli_grammar.Option;
const Conflict = cli_grammar.Conflict;
const PositionalConflict = cli_grammar.PositionalConflict;
const value = cli_grammar.value;
const numeric = cli_grammar.numeric;
const choice = cli_grammar.choice;
const flag = cli_grammar.flag;
const hex = cli_grammar.hex;
const hiddenValue = cli_grammar.hiddenValue;
pub const Command = enum {
    session_start,
    session_configure,
    session_send,
    session_inspect,
    session_list,
    session_stop,
    session_archive,
    session_unarchive,
    session_interrupt_model,
    session_read_conversation,
    session_resume,
    request_inspect,
    request_wait,
    request_recover,
    request_read_result,
    request_list,
    action_inspect,
    action_allow,
    action_deny,
    action_read_call_id,
    action_read_arguments,
    host_start,
    host_pause,
    host_status,
    host_serve,
    defaults_inspect,
    defaults_configure,
    auth_login,
    store_schema,

    pub fn definition(self: Command) Definition {
        // Option arrays have static storage, not a returned stack literal.
        return switch (self) {
            inline else => |command| comptime command.definitionValue(),
        };
    }

    fn definitionValue(self: Command) Definition {
        return switch (self) {
            .session_start => .{ .resource = .session, .name = "start", .description = "Read the first Message from stdin, atomically create a Session and admit that Message. Print a JSON mutation receipt with the new ID in .context.session, the request handle in .context.key and the resolved configuration, not a completed answer. Settings use fresh-Session defaults; set instructions separately with session configure --instructions -. Recover the original request as kind message after lost output.", .details = label_help, .options = destination ++ capture ++ binding ++ start_settings, .mutation = true },
            .session_configure => .{ .resource = .session, .name = "configure", .description = "Capture settings, including the Session's Label (its name or title), then admit configuration only. Omit the Session selector to create a fresh address with concrete defaults; addressed changes preserve omitted settings. --reload-skills only rescans this Session catalog, appends changed catalog instructions, and acknowledges without starting model work. Do not combine it with settings.", .details = compaction_help, .options = destination ++ session ++ capture ++ binding ++ settings ++ &[_]Option{flag("reload-skills")}, .conflicts = settings_conflicts, .mutation = true },
            .session_send => .{ .resource = .session, .name = "send", .description = "Read exact Message text from stdin and admit it to --to ID, exactly six lowercase Crockford characters (for example k7m2qx). Peers use their sender's Store and reject a conflicting --store. Without a sender, --store or saved Store defaults apply. Returns an admission receipt, before the recipient completes. Each /name word in the text that names one of the recipient's advertised skills appends that skill's complete SKILL.md and absolute path to what the model reads; the text itself is saved as written. Empty stdin sends nothing.", .options = destination ++ capture ++ &[_]Option{value("to", "ID")}, .mutation = true, .requires = &.{&.{"to"}} },
            .session_inspect => .{ .resource = .session, .name = "inspect", .description = "Read saved Session settings and work as JSON, or export exact retained failed-response bytes. Inspection never admits work.", .details = "--failed-response body|metadata requires --operation ID and --attempt N, excludes --profile, and writes only that stored byte stream to stdout. Redirect body output to a file; it can contain binary or private data. Missing records or omitted bodies fail on stderr. Partial bodies export their retained prefix; inspect metadata for status. No Host is started and no provider is contacted.\n", .options = destination ++ session ++ &[_]Option{ choice("profile", cli_value.ReportProfile), choice("failed-response", cli_value.FailedResponsePart), value("operation", "ID"), value("attempt", "N") }, .conflicts = &.{.{ .code = .profile_excludes_failed_response, .a = "profile", .b = "failed-response" }}, .requires = need_session },
            .session_list => .{ .resource = .session, .name = "list", .description = "List active Sessions in the current Workspace, or all Workspaces with --all, as one JSON value. --archived lists only archived Sessions; --include-archived includes both. --since TOKEN, the since of an earlier listing, lists only the Sessions that may have changed since it (delta changed), nothing (not_modified), or every Session (full).", .options = destination ++ &[_]Option{ flag("all"), flag("archived"), flag("include-archived"), value("since", "TOKEN") }, .conflicts = &.{.{ .code = .archive_visibility_conflict, .a = "archived", .b = "include-archived" }} },
            .session_stop => .{ .resource = .session, .name = "stop", .description = "Admit a stop for selected Session work. The stop is saved, so a restarted Host does not resume that work. The address remains reusable by later input; acknowledgment is not physical retirement. --all stops every Session in the Store that is pending, working, retrying, running Bash or awaiting approval, as overview Ctrl-X would, each as its own recoverable request with one JSON reply line and a recovery handle on stderr; it needs a running Host.", .options = destination ++ session ++ capture ++ &[_]Option{flag("all")}, .conflicts = &.{ .{ .code = .all_excludes_session, .a = "all", .b = "session" }, .{ .code = .all_excludes_record, .a = "all", .b = "record" }, .{ .code = .all_excludes_key, .a = "all", .b = "key" }, .{ .code = .all_excludes_key, .a = "all", .b = "key-hex" } }, .mutation = true, .requires = &.{&.{ "session", "all" }} },
            .session_archive => .{ .resource = .session, .name = "archive", .description = "Stop current and queued work, then archive once it has settled. The saved intent survives Host restart. Pending archival rejects new Messages; a later Message to an archived Session restores it. The receipt reports pending or completed archival.", .options = destination ++ session ++ capture, .mutation = true, .requires = need_session },
            .session_unarchive => .{ .resource = .session, .name = "unarchive", .description = "Restore an archived Session to active lists without resuming stopped work. Refused while archival is still settling.", .options = destination ++ session ++ capture, .mutation = true, .requires = need_session },
            .session_interrupt_model => .{ .resource = .session, .name = "interrupt-model", .description = "Interrupt the exact model Operation after inspecting its Session and Turn.", .options = destination ++ session ++ capture ++ &[_]Option{ value("turn", "ID"), value("operation", "ID") }, .mutation = true, .requires = need_session ++ &[_][]const []const u8{ &.{"turn"}, &.{"operation"} } },
            .session_read_conversation => .{ .resource = .session, .name = "read-conversation", .description = "Stream the exact saved public Conversation content at position and ordinal.", .options = destination ++ session ++ &[_]Option{ value("position", "POSITION"), value("ordinal", "ORDINAL") }, .requires = need_session ++ &[_][]const []const u8{ &.{"position"}, &.{"ordinal"} } },
            .session_resume => .{ .resource = .session, .name = "resume", .description = "Open an existing Session in the live terminal frontend. Requires terminal input/output; starts or attaches to a managed Host.", .options = destination ++ session, .positional = "ID", .positional_conflicts = &.{.{ .code = .session_selector_repeated, .option = "session" }}, .requires = &.{&.{ "", "session" }} },
            .request_inspect => .{ .resource = .request, .name = "inspect", .description = "Observe the original submitted command once. HANDLE loads its saved identity; --store and --key address it explicitly. Never transmits captured intent.", .options = destination ++ key, .positional = "HANDLE", .positional_conflicts = saved_identity, .requires = &.{&.{ "", "key", "key-hex" }} },
            .request_wait => .{ .resource = .request, .name = "wait", .description = "Wait for the original request to end or need permission. Prints the latest request inspect JSON, never an answer or token. Polls without holding capture or Host resources and never starts, resumes or retargets work. --timeout-seconds defaults to 300 (1..86400). Exits 0 when ended or waiting for permission, 5 on timeout or signal while pending, 4 if absent: rui request recover HANDLE.", .options = destination ++ key ++ &[_]Option{numeric("timeout-seconds", "N", 1, @import("request_wait.zig").max_timeout_seconds, .count_malformed)}, .positional = "HANDLE", .positional_conflicts = saved_identity, .requires = &.{&.{ "", "key", "key-hex" }} },
            .request_recover => .{ .resource = .request, .name = "recover", .description = "Retransmit the original saved command and inputs. This may first admit work if the original never committed. Use HANDLE, or --store PATH --record FILE --kind KIND.", .options = destination ++ &[_]Option{ value("record", "FILE"), choice("kind", cli_value.RecoveryKind) }, .positional = "HANDLE", .positional_conflicts = &.{ .{ .code = .handle_names_store_record_and_kind, .option = "store" }, .{ .code = .handle_names_store_record_and_kind, .option = "store-hex" }, .{ .code = .handle_names_store_record_and_kind, .option = "record" }, .{ .code = .handle_names_store_record_and_kind, .option = "kind" } }, .mutation = true, .requires = &.{&.{ "", "record" }} },
            .request_read_result => .{ .resource = .request, .name = "read-result", .description = "Stream the originally bound saved answer, skill refusal or reload acknowledgement, without waiting or substituting newer Session work. Use HANDLE or --store and --key.", .options = destination ++ key, .positional = "HANDLE", .positional_conflicts = saved_identity, .requires = &.{&.{ "", "key", "key-hex" }} },
            .request_list => .{ .resource = .request, .name = "list", .description = "Enumerate local generated captures as JSON. This is not Store history or guaranteed correlation after all output from concurrent calls is lost." },
            .action_inspect => .{ .resource = .action, .name = "inspect", .description = "Read the exact saved Action proposal before allowing or denying it. Inspection grants nothing.", .options = destination ++ session ++ action, .requires = need_action },
            .action_allow => .{ .resource = .action, .name = "allow", .description = "Admit permission to run this exact inspected Action once; the Host revalidates its target.", .options = destination ++ session ++ action ++ capture, .mutation = true, .requires = need_action },
            .action_deny => .{ .resource = .action, .name = "deny", .description = "Admit denial of this exact inspected Action.", .options = destination ++ session ++ action ++ capture, .mutation = true, .requires = need_action },
            .action_read_call_id => .{ .resource = .action, .name = "read-call-id", .description = "Stream the exact saved Action call ID bytes.", .options = destination ++ session ++ action, .requires = need_action },
            .action_read_arguments => .{ .resource = .action, .name = "read-arguments", .description = "Stream the exact saved Action argument bytes.", .options = destination ++ session ++ action, .requires = need_action },
            .host_start => .{ .resource = .host, .name = "start", .description = std.fmt.comptimePrint("Explicitly start or connect to a managed Host. A new Host gets --active-capacity N, default {d}; an already-running Host keeps its original settings, including capacity, as rui host status reports, and stderr says so when --active-capacity differs.", .{product_defaults.active_capacity}), .options = destination ++ &[_]Option{value("active-capacity", "N")} },
            .host_pause => .{ .resource = .host, .name = "pause", .description = std.fmt.comptimePrint("Shut down the Host, interrupting all work in this Store. Saved work resumes when a Host starts again, including on the next rui; to end a Session's work for good, use rui session stop. Waits up to {d} seconds for the Host to release the Store and reports retirement confirmed or unconfirmed. Retry lost acknowledgment with the original --instance only.", .{product_defaults.host_shutdown_seconds}), .options = destination ++ &[_]Option{value("instance", "HEX")} },
            .host_status => .{ .resource = .host, .name = "status", .description = "Read protected Host readiness and capabilities without starting it.", .options = destination },
            .host_serve => serve_grammar.definition,
            .defaults_inspect => .{ .resource = .defaults, .name = "inspect", .description = "Read future-Session defaults without writing preferences or changing Sessions." },
            .defaults_configure => .{ .resource = .defaults, .name = "configure", .description = "Save explicit future-Session defaults and the notification choice. Existing Sessions are unchanged. --store sets the global default Store for commands without --store (saved requests keep their recorded Store), and stderr names it. --clear-model removes only the saved model. --notifications on|off chooses whether an open overview or conversation sends a desktop notification, while its terminal is out of focus, when a Session finishes, fails or needs approval; on by default. --reasoning-effort sets the effort new Sessions start at when their model offers it, as /effort LEVEL in a conversation does; default uses the client product choice.", .options = destination ++ binding ++ &[_]Option{ flag("clear-model"), notifications, settingOption("reasoning_effort") }, .conflicts = &.{.{ .code = .model_excludes_clear_model, .a = "model", .b = "clear-model" }}, .requires = &.{&.{ "store", "store-hex", "provider", "model", "clear-model", "notifications", "reasoning-effort" }} },
            .store_schema => .{ .resource = .store, .name = "schema", .description = "Print this build's MySQL DDL for a new Store, or with --from N print every forward migration from format N to this build. The current format prints nothing. The Host never changes MySQL tables.", .options = &.{ value("engine", "mysql"), numeric("from", "N", 0, std.math.maxInt(u64), .count_malformed) }, .requires = &.{&.{"engine"}} },
            .auth_login => .{ .resource = .auth, .name = "login", .description = "Explicit operator sign-in: rui auth login codex signs in with ChatGPT; rui auth login openai saves an OpenAI API key read from stdin. Ordinary peer calls never sign in or prompt.", .positional = "PROVIDER", .requires = &.{&.{""}} },
        };
    }
};

/// Shared by this help and the interactive /configure usage.
pub const compaction_policy =
    \\--compaction-trigger TOKENS|default sets a positive estimated context pressure threshold.
    \\--output-reservation TOKENS|default sets nonnegative extra compaction headroom, not a guaranteed output budget.
    \\Omission preserves an existing Session's setting; default resets it to client policy.
    \\Changes apply to new model requests. Requests already accepted keep their original settings, even when retried.
    \\
++ std.fmt.comptimePrint("A model Rui does not list is assumed to have a {d}-token context.", .{product_defaults.unlisted_context_window});

/// Shared by `session configure`, `session start` and the interactive /configure.
pub const label_help =
    \\--label TEXT names, renames or titles the Session, shown in lists and /status: one line of at most 100 bytes. --label "" clears it.
    \\A Label is display text only; it never addresses or selects a Session.
    \\
;

pub const reasoning_help =
    \\--reasoning-effort VALUE selects a model-supported effort; default selects the client default.
    \\Omission preserves an existing choice. New Sessions and resets prefer low, else the lowest listed effort.
    \\
++ "Efforts depend on the model: none, low, medium, high, xhigh and max" ++
    (if (model_capability.ids_without_max_effort.len == 0) "" else ". max is not listed for: " ++ model_capability.ids_without_max_effort) ++
    ". The catalog lists which each model accepts.\n" ++
    \\The setting applies to new model requests, including compaction; retries keep their frozen effort.
    \\
;

const compaction_help = label_help ++ reasoning_help ++ compaction_policy ++
    \\ Inspect settings with rui session inspect.
    \\Omit --session to allocate a new six-character ID. --session ID updates only an existing Session; unknown IDs never create one.
    \\
++ model_capability.model_help ++ "These release-supported IDs do not guarantee account availability or live qualification.\n";

const destination = serve_grammar.destination;
const session = &[_]Option{value("session", "ID")};
const key = &[_]Option{ value("key", "KEY"), hex("key-hex", "key", 128) };
const capture = &[_]Option{ value("record", "FILE"), value("key", "KEY"), hex("key-hex", "key", 128), hiddenValue("test-drop-reply") };
const binding = settingOptions(.binding, false);
const notifications = choice("notifications", cli_value.Notification);
const action = &[_]Option{value("action", "ID")};
const need_session = &[_][]const []const u8{&.{"session"}};
const need_action = need_session ++ &[_][]const []const u8{&.{"action"}};
/// A saved request HANDLE names its own Store and key.
const saved_identity = &[_]PositionalConflict{
    .{ .code = .handle_names_store_and_key, .option = "store" },
    .{ .code = .handle_names_store_and_key, .option = "store-hex" },
    .{ .code = .handle_names_store_and_key, .option = "key" },
    .{ .code = .handle_names_store_and_key, .option = "key-hex" },
};
const tool_choices = blk: {
    var text: []const u8 = "";
    for (std.enums.values(@import("built_in_tool.zig").BuiltInTool), 0..) |tool, i| {
        text = text ++ (if (i == 0) "" else ",") ++ @tagName(tool);
    }
    break :blk text ++ "|none";
};
/// Session settings shared by `session configure` and the live /configure.
const settings = settingOptions(.settings, false);
const start_settings = settingOptions(.settings, true);

fn settingOptions(comptime group: @FieldType(session_settings.Cli, "group"), comptime on_start: bool) []const Option {
    var options: []const Option = &.{};
    for (session_settings.entries) |entry| {
        const cli = entry.cli orelse continue;
        if (cli.group != group or (on_start and !cli.on_start)) continue;
        options = options ++ .{settingOption(entry.field)};
        // A CLI-only clearing alias, beside the content option it clears.
        if (std.mem.eql(u8, entry.field, "output_schema")) options = options ++ .{flag("text-output")};
    }
    return options;
}

/// Argument shapes and aliases belong to the CLI, not to a Session setting.
fn settingOption(comptime field: []const u8) Option {
    for (session_settings.entries) |entry| {
        if (!std.mem.eql(u8, entry.field, field)) continue;
        const cli = entry.cli orelse @compileError("setting has no CLI option: " ++ field);
        return switch (entry.kind) {
            .text => value(cli.name, if (std.mem.eql(u8, field, "workspace")) "PATH" else if (std.mem.eql(u8, field, "model")) "MODEL" else "TEXT"),
            .content => value(cli.name, if (entry.nullable) "FILE|-" else "-"),
            .tools => value(cli.name, if (std.mem.eql(u8, field, "tools")) tool_choices else "a,b|none"),
            .decimal_policy => value(cli.name, "TOKENS|default"),
            .choice => if (std.mem.eql(u8, field, "provider")) choice(cli.name, provider_name.Provider) else if (std.mem.eql(u8, field, "permission_mode")) choice(cli.name, cli_value.PermissionMode) else if (std.mem.eql(u8, field, "reasoning_effort")) choice(cli.name, cli_value.ReasoningChoice) else @compileError("choose CLI values for " ++ field),
        };
    }
    @compileError("unknown Session setting: " ++ field);
}

const settings_conflicts = &[_]Conflict{.{ .code = .output_schema_excludes_text_output, .a = "output-schema", .b = "text-output" }};
/// The bare `rui` entry, which has no resource help of its own.
pub const fresh_session: Definition = .{ .resource = .session, .name = "", .description = "", .options = &.{ value("store", "PATH"), settingOption("provider"), settingOption("model") } };
/// The live Session's /configure: settings only; the Session is its address.
pub const live_configure: Definition = .{ .resource = .session, .name = "/configure", .description = "", .options = binding ++ settings ++ &[_]Option{flag("reload-skills")}, .conflicts = settings_conflicts };
/// The live Session's /setup: the defaults grammar, where none means inspect.
pub const live_setup: Definition = .{ .resource = .defaults, .name = "/setup", .description = "", .options = &.{ value("store", "PATH"), settingOption("provider"), settingOption("model"), flag("clear-model"), notifications, settingOption("reasoning_effort") }, .conflicts = &.{.{ .code = .model_excludes_clear_model, .a = "model", .b = "clear-model" }} };

/// Every grammar contributes its options, including hex spellings and hidden flags.
const option_names = blk: {
    @setEvalBranchQuota(100_000);
    var grammars: []const Definition = &.{ fresh_session, live_configure, live_setup };
    for (std.enums.values(Command)) |command| grammars = grammars ++ .{command.definition()};
    var names: []const []const u8 = &.{};
    for (grammars) |grammar| {
        for (grammar.options) |option| {
            for (names) |name| {
                if (std.mem.eql(u8, name, option.name)) break;
            } else {
                names = names ++ .{option.name};
            }
        }
    }
    break :blk names;
};

fn hasOptionName(name: []const u8) bool {
    for (option_names) |candidate| if (std.mem.eql(u8, candidate, name)) return true;
    return false;
}

comptime {
    @setEvalBranchQuota(100_000);
    for (option_names) |name| {
        if (!option_manifest.contains(name)) @compileError("add option to cli_option_names.zig: " ++ name);
    }
    for (option_manifest.names) |name| {
        if (!hasOptionName(name)) @compileError("remove unused option from cli_option_names.zig: " ++ name);
    }
}

pub fn resourceHelp(resource: Resource, writer: *std.Io.Writer) !void {
    try writer.print("rui {s} COMMAND\n", .{@tagName(resource)});
    inline for (comptime std.meta.tags(Command)) |command| {
        const definition = command.definition();
        if (definition.resource == resource) try writer.print("  {s}: {s}\n", .{ definition.name, definition.description });
    }
    try writer.print("Use rui {s} COMMAND --help for options.\n", .{@tagName(resource)});
}

/// Former commands and their replacements: top-level names, refused rather
/// than read as a fresh conversation's prompt, and `RESOURCE OPERATION` pairs.
/// `host stop` became `host pause` because the next Host resumes its work.
const retired_names = [_][2][]const u8{
    .{ "exec", "session configure|send" },                 .{ "follow", "request inspect" },                      .{ "wait-session", "session inspect" },
    .{ "result", "request read-result" },                  .{ "setup", "defaults inspect|configure" },            .{ "serve", "host serve" },
    .{ "login", "auth login" },                            .{ "configure", "session configure" },                 .{ "message", "session send" },
    .{ "inspect-session", "session inspect" },             .{ "sessions", "session list" },                       .{ "stop-session", "session stop" },
    .{ "interrupt-model", "session interrupt-model" },     .{ "read-conversation", "session read-conversation" }, .{ "resume", "session resume" },
    .{ "observe-command", "request inspect" },             .{ "recover", "request recover" },                     .{ "retry", "request recover" },
    .{ "read-result", "request read-result" },             .{ "requests", "request list" },                       .{ "inspect-action", "action inspect" },
    .{ "allow-action", "action allow" },                   .{ "deny-action", "action deny" },                     .{ "read-action-call-id", "action read-call-id" },
    .{ "read-action-arguments", "action read-arguments" }, .{ "host stop", "host pause" },
};

pub fn retired(name: []const u8) ?[]const u8 {
    for (retired_names) |entry| if (std.mem.eql(u8, entry[0], name)) return entry[1];
    return null;
}

pub fn find(resource: Resource, name: []const u8) ?Command {
    inline for (comptime std.meta.tags(Command)) |command| {
        const definition = command.definition();
        if (definition.resource == resource and std.mem.eql(u8, definition.name, name)) return command;
    }
    return null;
}

fn testParse(definition: Definition, args: []const []const u8, storage: []u8) Definition.Error!Parsed {
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    var problem: Refusal = undefined;
    return definition.parse(args, fixed.allocator(), &problem);
}

/// `expected` is the help request of a valid invocation.
fn expectValidation(command: Command, args: []const []const u8, expected: anyerror!bool) !void {
    var storage: [1024]u8 = undefined;
    const parsed = testParse(command.definition(), args, &storage);
    if (expected) |help| {
        try std.testing.expectEqual(help, (try parsed).help);
    } else |err| try std.testing.expectError(err, parsed);
}

fn expectMissing(command: Command, args: []const []const u8) !?[]const u8 {
    var storage: [1024]u8 = undefined;
    const parsed = try testParse(command.definition(), args, &storage);
    return if (parsed.missing()) |group| group[0] else null;
}

test "option name set covers every grammar and rejects unknown names" {
    for (std.enums.values(Command)) |command| {
        for (command.definition().options) |option| try std.testing.expect(hasOptionName(option.name));
    }
    for ([_]Definition{ fresh_session, live_configure, live_setup }) |grammar| {
        for (grammar.options) |option| try std.testing.expect(hasOptionName(option.name));
    }
    try std.testing.expect(!hasOptionName("made-up-option-name"));
}

test "grammar rejects ambiguous invocations before any effect" {
    try expectValidation(.session_send, &.{ "--to", "a", "--to", "a", "hi" }, error.DuplicateArgument);
    try expectValidation(.session_send, &.{ "--to", "a", "--text", "f" }, error.UnknownArgument);
    try expectValidation(.session_send, &.{ "--to", "a", "hi", "again" }, error.InvalidArguments);
    try expectValidation(.session_send, &.{ "--to", "a", "--bogus" }, error.UnknownArgument);
    for ([_][]const u8{ "--session", "--session-hex" }) |old|
        try expectValidation(.session_send, &.{ "--to", "a", old, "value", "hi" }, error.UnknownArgument);
    try expectValidation(.session_send, &.{ "--store", "path", "--to", "k7m2qx" }, false);
    try expectValidation(.session_send, &.{"--to"}, error.MissingArgumentValue);
    try expectValidation(.session_configure, &.{ "--output-schema", "f", "--text-output" }, error.ConflictingArguments);
    try expectValidation(.defaults_configure, &.{ "--model", "m", "--clear-model" }, error.ConflictingArguments);
    try expectValidation(.request_inspect, &.{ "--key", "k", "HANDLE" }, error.ConflictingArguments);
    try expectValidation(.request_wait, &.{ "--key", "k", "HANDLE" }, error.ConflictingArguments);
    // --all stops every busy Session, each under its own generated capture.
    try expectValidation(.session_stop, &.{ "--store", "/s", "--all" }, false);
    for ([_][]const u8{ "--session", "--record", "--key", "--key-hex" }) |single|
        try expectValidation(.session_stop, &.{ "--all", single, "6b" }, error.ConflictingArguments);
    try expectValidation(.session_list, &.{"--json"}, error.UnknownArgument);
    // Values are data, but Message text has no argv spelling.
    try expectValidation(.session_send, &.{ "--to", "--help" }, false);
    try expectValidation(.session_send, &.{ "--to", "a", "--", "-" }, error.InvalidArguments);
    try expectValidation(.session_send, &.{ "--to", "a", "-" }, error.InvalidArguments);
    try expectValidation(.session_start, &.{"inline text"}, error.InvalidArguments);
    try expectValidation(.session_start, &.{ "--instructions", "-" }, error.UnknownArgument);
    try expectValidation(.session_configure, &.{ "--instructions", "file" }, error.InvalidInstructionsSource);
    try expectValidation(.session_configure, &.{ "--instructions", "-", "--output-schema", "-" }, error.ConflictingArguments);
    try expectValidation(.session_configure, &.{ "--instructions", "-" }, false);
    try expectValidation(.session_send, &.{ "--to", "a", "--help" }, true);
    try expectValidation(.session_resume, &.{ "--store", "/s", "REF" }, false);
    try expectValidation(.session_resume, &.{ "--session", "a", "REF" }, error.ConflictingArguments);
    // Resume is exact; there is no newest-Session guess.
    try expectValidation(.session_resume, &.{ "--store", "/s", "--last" }, error.UnknownArgument);
    try expectValidation(.host_serve, &.{ "--test-phase-trace", "--fault", "before-commit", "--provider", "codex" }, false);
    try expectValidation(.session_list, &.{"--test-drop-reply"}, error.UnknownArgument);
}

test "every advertised operation is reachable through its own resource" {
    inline for (comptime std.meta.tags(Command)) |command| {
        const definition = command.definition();
        try std.testing.expectEqual(command, find(definition.resource, definition.name).?);
        try std.testing.expect(definition.options.len <= 64);
    }
    try std.testing.expect(find(.session, "exec") == null);
    try std.testing.expect(find(.request, "follow") == null);
}

test "every grammar's conflict and spelling data names its own options" {
    const live = [_]Definition{ fresh_session, live_configure, live_setup };
    inline for (comptime std.meta.tags(Command)) |command| try expectCoherent(command.definition());
    for (live) |definition| try expectCoherent(definition);
}

fn expectCoherent(definition: Definition) !void {
    try std.testing.expect(definition.options.len <= 64);
    for (definition.conflicts) |pair| {
        try std.testing.expect(definition.indexOf(pair.a) != null and definition.indexOf(pair.b) != null);
    }
    for (definition.positional_conflicts) |conflict| try std.testing.expect(definition.positional != null and definition.indexOf(conflict.option) != null);
    for (definition.options) |option| if (option.hex_of) |named| {
        try std.testing.expect(definition.indexOf(named) != null and option.hex_limit != 0);
    };
}

test "a hex spelling fills its named option and conflicts with it" {
    var storage: [1024]u8 = undefined;
    const plain = try testParse(Command.session_inspect.definition(), &.{ "--store", "/a/b", "--session", "k7m2qx" }, &storage);
    const spelled = try testParse(Command.session_inspect.definition(), &.{ "--store-hex", "2f612f62", "--session", "k7m2qx" }, &storage);
    try std.testing.expectEqualStrings(plain.get("store").?, spelled.get("store").?);
    try std.testing.expect(spelled.has("store-hex") and !spelled.has("store"));
    try expectValidation(.session_inspect, &.{ "--store", "a", "--store-hex", "61" }, error.ConflictingArguments);
    try expectValidation(.session_inspect, &.{ "--store-hex", "61", "--store", "a" }, error.ConflictingArguments);
    // Odd, non-hex, over-bound and non-UTF-8 spellings all fail; help wins.
    const store_over: [2 * 493]u8 = @splat('6');
    inline for (.{ "6", "zz", "ff", &store_over }) |bad| try expectValidation(.session_inspect, &.{ "--store-hex", bad, "--session", "k7m2qx" }, error.InvalidHexIdentity);
    try expectValidation(.session_inspect, &.{ "--store-hex", &store_over, "--session", "a" }, error.InvalidHexIdentity);
    try expectValidation(.session_inspect, &.{ "--store-hex", store_over[2..], "--session", "a" }, false);
    try expectValidation(.session_inspect, &.{ "--store-hex", "zz", "--help" }, true);
    try expectValidation(.session_inspect, &.{ "--session-hex", "6b376d327178" }, error.UnknownArgument);
}

test "hidden test options belong to their operation and stay out of help" {
    var storage: [1024]u8 = undefined;
    const serve = try testParse(Command.host_serve.definition(), &.{ "--fault", "before-commit", "--test-phase-trace", "--fault", "content-read", "--test-retry-waits-ms", "1,1,1" }, &storage);
    try std.testing.expectEqual(@as(usize, 2), serve.all("fault").len);
    try std.testing.expectEqualStrings("content-read", serve.all("fault")[1]);
    // Two repeatable options keep their own values, in order.
    var mixed_storage: [1024]u8 = undefined;
    const mixed = try testParse(Command.host_serve.definition(), &.{ "--fault", "a", "--provider", "codex", "--fault", "b", "--provider", "openai" }, &mixed_storage);
    try std.testing.expectEqualSlices([]const u8, &.{ "a", "b" }, mixed.all("fault"));
    try std.testing.expectEqualSlices([]const u8, &.{ "codex", "openai" }, mixed.all("provider"));
    try std.testing.expectEqual(@as(usize, 0), mixed.all("store").len);
    try std.testing.expect(serve.has("test-phase-trace") and serve.get("test-phase-trace") == null);
    try std.testing.expectEqualStrings("1,1,1", serve.get("test-retry-waits-ms").?);
    try expectValidation(.host_serve, &.{ "--test-phase-trace", "--test-phase-trace" }, error.DuplicateArgument);
    try expectValidation(.host_serve, &.{"--test-unknown"}, error.UnknownArgument);
    try expectValidation(.session_list, &.{"--fault"}, error.UnknownArgument);
    try expectValidation(.session_stop, &.{ "--session", "a", "--test-drop-reply", "x" }, false);
    try expectValidation(.request_recover, &.{ "HANDLE", "--test-drop-reply", "x" }, error.UnknownArgument);
    var bytes: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try Command.host_serve.definition().help(&writer);
    try Command.session_send.definition().help(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "--test-") == null and std.mem.indexOf(u8, writer.buffered(), "--fault") == null);
}

test "live /configure and /setup share the one-shot grammar" {
    // Every live setting is the same option, with the same value shape.
    for (live_configure.options) |option| {
        const shared = Command.session_configure.definition().optionNamed(option.name).?;
        try std.testing.expectEqual(option.argument == null, shared.argument == null);
    }
    for ([_][]const u8{ "default", "none", "low", "medium", "high", "xhigh", "max" }) |effort| {
        var argument_storage: [256]u8 = undefined;
        const parsed = try testParse(live_configure, &.{ "--reasoning-effort", effort }, &argument_storage);
        try std.testing.expectEqualStrings(effort, parsed.get("reasoning-effort").?);
        const one_shot = try testParse(Command.session_configure.definition(), &.{ "--reasoning-effort", effort }, &argument_storage);
        try std.testing.expectEqualStrings(effort, one_shot.get("reasoning-effort").?);
    }
    for (live_setup.options) |option| try std.testing.expect(Command.defaults_configure.definition().optionNamed(option.name) != null);
    var storage: [256]u8 = undefined;
    try std.testing.expectError(error.UnknownArgument, testParse(live_configure, &.{ "--session", "other" }, &storage));
    try std.testing.expectError(error.ConflictingArguments, testParse(live_configure, &.{ "--text-output", "--output-schema", "f" }, &storage));
    try std.testing.expectError(error.ConflictingArguments, testParse(live_setup, &.{ "--clear-model", "--model", "m" }, &storage));
    try std.testing.expectError(error.InvalidArguments, testParse(fresh_session, &.{ "--model", "m", "--", "--store" }, &storage));
    try std.testing.expectError(error.DuplicateArgument, testParse(fresh_session, &.{ "--model", "m", "--model", "n" }, &storage));
}

test "complete syntax still names the first missing requirement" {
    try std.testing.expectEqualStrings("to", (try expectMissing(.session_send, &.{})).?);
    try std.testing.expect(try expectMissing(.session_send, &.{ "--to", "a" }) == null);
    try std.testing.expectEqualStrings("record", (try expectMissing(.session_send, &.{ "--to", "a", "--key", "k" })).?);
    try std.testing.expectEqualStrings("key", (try expectMissing(.session_send, &.{ "--to", "a", "--record", "r" })).?);
    try std.testing.expect(try expectMissing(.session_send, &.{ "--to", "a", "--test-drop-reply", "x" }) == null);
    try std.testing.expect(try expectMissing(.session_resume, &.{ "--store", "/s", "--session", "a" }) == null);
    try std.testing.expect(try expectMissing(.session_resume, &.{ "--store", "/s" }) != null);
    try std.testing.expect(try expectMissing(.session_stop, &.{"--all"}) == null);
    try std.testing.expect(try expectMissing(.session_stop, &.{ "--store", "/s" }) != null);
    try std.testing.expect(try expectMissing(.request_recover, &.{"HANDLE"}) == null);
    try std.testing.expectEqualStrings("kind", (try expectMissing(.request_recover, &.{ "--record", "r" })).?);
    try std.testing.expect(try expectMissing(.defaults_configure, &.{}) != null);
    try std.testing.expect(try expectMissing(.session_configure, &.{}) == null);
    try std.testing.expectEqualStrings("defaults inspect|configure", retired("setup").?);
    try std.testing.expect(retired("session") == null and retired("fix the build") == null);
    try std.testing.expectEqualStrings("host pause", retired("host stop").?);
    try std.testing.expect(retired("session stop") == null and find(.host, "stop") == null);
}

test "Host start help states the product default capacity and existing-Host precedence" {
    const capacity = std.fmt.comptimePrint("{d}", .{product_defaults.active_capacity});
    inline for (.{ Command.host_start, Command.host_serve }) |command| {
        var bytes: [2048]u8 = undefined;
        var writer = std.Io.Writer.fixed(&bytes);
        try command.definition().help(&writer);
        const text = writer.buffered();
        try std.testing.expect(std.mem.indexOf(u8, text, capacity ++ ".") != null or std.mem.indexOf(u8, text, capacity ++ ";") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "capacity-8") == null and std.mem.indexOf(u8, text, "1000") == null);
    }
    var bytes: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&bytes);
    try Command.host_start.definition().help(&writer);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "already-running Host keeps its original settings, including capacity") != null);
}

test "store schema requires an explicit mysql engine" {
    const definition = Command.store_schema.definition();
    var storage: [1024]u8 = undefined;
    const parsed = try testParse(definition, &.{ "--engine", "mysql" }, &storage);
    try std.testing.expect(parsed.missing() == null);
    try std.testing.expectEqualStrings("mysql", parsed.get("engine").?);
    try expectValidation(.store_schema, &.{ "--store", "/tmp/s" }, error.UnknownArgument);
}

test "store schema --from parses formats and requires an explicit engine" {
    const definition = Command.store_schema.definition();
    var storage: [1024]u8 = undefined;
    for ([_]u64{ 0, 1, std.math.maxInt(u32) + 1, std.math.maxInt(u64) }) |from| {
        var text: [32]u8 = undefined;
        const parsed = try testParse(definition, &.{ "--engine", "mysql", "--from", try std.fmt.bufPrint(&text, "{d}", .{from}) }, &storage);
        try std.testing.expect(parsed.missing() == null);
        try std.testing.expectEqual(@as(?u64, from), try parsed.number(u64, "from"));
    }
    const missing = try testParse(definition, &.{ "--from", "1" }, &storage);
    try std.testing.expectEqualStrings("engine", missing.missing().?[0]);
    try expectValidation(.store_schema, &.{ "--engine", "mysql", "--from", "not-a-number" }, error.InvalidOptionValue);
    try expectValidation(.store_schema, &.{ "--engine", "mysql", "--from" }, error.MissingArgumentValue);
}

test "loaded tools are accepted beside tools on configure and start" {
    inline for (.{ Command.session_configure.definition(), Command.session_start.definition(), live_configure }) |grammar| {
        var storage: [256]u8 = undefined;
        const parsed = try testParse(grammar, &.{ "--tools", "bash,web_search", "--loaded-tools", "bash" }, &storage);
        try std.testing.expectEqualStrings("bash,web_search", parsed.get("tools").?);
        try std.testing.expectEqualStrings("bash", parsed.get("loaded-tools").?);
        try std.testing.expectError(error.DuplicateArgument, testParse(grammar, &.{ "--loaded-tools", "none", "--loaded-tools", "bash" }, &storage));
    }
}

fn expectRefusal(command: Command, args: []const []const u8, code: caller_error.Code, token: []const u8) !Refusal {
    var storage: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var refusal: Refusal = undefined;
    if (command.definition().parse(args, fixed.allocator(), &refusal)) |_| return error.ExpectedRefusal else |_| {}
    try std.testing.expectEqual(code, refusal.code);
    try std.testing.expectEqualStrings(token, refusal.token);
    return refusal;
}

test "parser refusals identify each invocation cause and its witness" {
    _ = try expectRefusal(.session_list, &.{"--bogus"}, .option_unknown, "--bogus");
    _ = try expectRefusal(.session_send, &.{ "--to", "a", "--to", "b" }, .option_repeated, "to");
    _ = try expectRefusal(.session_send, &.{"--to"}, .option_value_missing, "to");
    _ = try expectRefusal(.session_list, &.{"literal"}, .positional_unexpected, "literal");
    _ = try expectRefusal(.session_start, &.{"literal"}, .message_not_stdin, "literal");
    const bad_hex = try expectRefusal(.session_inspect, &.{ "--store-hex", "zz" }, .hex_malformed, "store-hex");
    try std.testing.expectEqualStrings("zz", bad_hex.value.?);
    try std.testing.expectEqualStrings("nonempty even-length hex of at most 492 UTF-8 bytes", bad_hex.accepted.?.grammar);
    _ = try expectRefusal(.session_configure, &.{ "--instructions", "file" }, .instructions_source, "instructions");
    _ = try expectRefusal(.session_configure, &.{ "--instructions", "-", "--output-schema", "-" }, .stdin_sources_conflict, "instructions");
    _ = try expectRefusal(.session_inspect, &.{ "--store", "s", "--store-hex", "73" }, .identity_spelling_repeated, "store");
    var repeated: [34][]const u8 = undefined;
    for (0..17) |i| {
        repeated[2 * i] = "--provider";
        repeated[2 * i + 1] = "codex";
    }
    _ = try expectRefusal(.host_serve, &repeated, .option_repeat_limit, "provider");
    var nothing: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&nothing);
    var refusal: Refusal = undefined;
    try std.testing.expectError(error.OutOfMemory, Command.session_inspect.definition().parse(&.{ "--store-hex", "73" }, fixed.allocator(), &refusal));
    try std.testing.expectEqual(.memory_exhausted, refusal.code);
}

test "every declared conflict emits its own catalog code" {
    inline for (comptime std.meta.tags(Command)) |command| {
        const definition = command.definition();
        for (definition.conflicts) |conflict| {
            var storage: [6][]const u8 = undefined;
            var tokens: usize = 0;
            // Format the two trusted flag names in bounded local storage.
            var first: [128]u8 = undefined;
            var second: [128]u8 = undefined;
            storage[tokens] = try std.fmt.bufPrint(&first, "--{s}", .{conflict.a});
            tokens += 1;
            if (definition.optionNamed(conflict.a).?.argument != null) {
                storage[tokens] = "x";
                tokens += 1;
            }
            storage[tokens] = try std.fmt.bufPrint(&second, "--{s}", .{conflict.b});
            tokens += 1;
            if (definition.optionNamed(conflict.b).?.argument != null) {
                storage[tokens] = "x";
                tokens += 1;
            }
            const refusal = try expectRefusal(command, storage[0..tokens], conflict.code, conflict.a);
            try std.testing.expectEqualStrings(conflict.b, refusal.other.?);
        }
        for (definition.positional_conflicts) |conflict| {
            var spelling: [128]u8 = undefined;
            const refusal = try expectRefusal(command, &.{ "HANDLE", try std.fmt.bufPrint(&spelling, "--{s}", .{conflict.option}), "x" }, conflict.code, conflict.option);
            try std.testing.expectEqualStrings(definition.positional.?, refusal.other.?);
        }
    }
}

test "typed choices share enum names with help and refuse unknown values" {
    const Case = struct { command: Command, name: []const u8, choices: []const []const u8 };
    const cases = [_]Case{
        .{ .command = .session_start, .name = "permission-mode", .choices = &.{ "ask", "bypass" } },
        .{ .command = .session_start, .name = "provider", .choices = &.{ "codex", "openai" } },
        .{ .command = .session_configure, .name = "reasoning-effort", .choices = &.{ "none", "low", "medium", "high", "xhigh", "max", "default" } },
        .{ .command = .defaults_configure, .name = "notifications", .choices = &.{ "on", "off" } },
        .{ .command = .request_recover, .name = "kind", .choices = &.{ "configure", "message", "session-stop", "session-archive", "model-interruption", "permission-decision" } },
        .{ .command = .session_inspect, .name = "profile", .choices = &.{ "current", "full" } },
        .{ .command = .session_inspect, .name = "failed-response", .choices = &.{ "body", "metadata" } },
        .{ .command = .host_serve, .name = "provider", .choices = &.{ "codex", "openai" } },
    };
    for (cases) |case| {
        var spelling: [64]u8 = undefined;
        const flag_name = try std.fmt.bufPrint(&spelling, "--{s}", .{case.name});
        const refusal = try expectRefusal(case.command, &.{ flag_name, "unsupported" }, .choice_unsupported, case.name);
        try std.testing.expectEqualStrings("unsupported", refusal.value.?);
        try std.testing.expectEqual(case.choices.len, refusal.accepted.?.closed.len);
        for (case.choices, refusal.accepted.?.closed) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
        const option = case.command.definition().optionNamed(case.name).?;
        var placeholder = std.mem.splitScalar(u8, option.argument.?, '|');
        for (case.choices) |expected| {
            try std.testing.expectEqualStrings(expected, placeholder.next().?);
            var storage: [1024]u8 = undefined;
            _ = try testParse(case.command.definition(), &.{ flag_name, expected }, &storage);
        }
        try std.testing.expect(placeholder.next() == null);
        var storage: [1024]u8 = undefined;
        const help = try testParse(case.command.definition(), &.{ flag_name, "unsupported", "--help" }, &storage);
        try std.testing.expect(help.help);
    }
}

test "numeric options reject malformed decimals and state their accepted range" {
    const Case = struct { command: Command, name: []const u8, code: caller_error.Code, low: []const u8, high: []const u8 };
    const cases = [_]Case{
        .{ .command = .action_inspect, .name = "action", .code = .id_malformed, .low = "1", .high = "9223372036854775807" },
        .{ .command = .session_interrupt_model, .name = "turn", .code = .id_malformed, .low = "1", .high = "9223372036854775807" },
        .{ .command = .session_interrupt_model, .name = "operation", .code = .id_malformed, .low = "1", .high = "9223372036854775807" },
        .{ .command = .session_read_conversation, .name = "position", .code = .id_malformed, .low = "1", .high = "9223372036854775807" },
        .{ .command = .session_read_conversation, .name = "ordinal", .code = .count_malformed, .low = "0", .high = "9223372036854775807" },
        .{ .command = .session_inspect, .name = "attempt", .code = .count_malformed, .low = "1", .high = "9223372036854775807" },
        .{ .command = .request_wait, .name = "timeout-seconds", .code = .count_malformed, .low = "1", .high = "86400" },
        .{ .command = .store_schema, .name = "from", .code = .count_malformed, .low = "0", .high = std.fmt.comptimePrint("{d}", .{std.math.maxInt(u64)}) },
        .{ .command = .host_start, .name = "active-capacity", .code = .count_malformed, .low = "0", .high = std.fmt.comptimePrint("{d}", .{std.math.maxInt(usize)}) },
        .{ .command = .host_serve, .name = "test-retention-entry-capacity", .code = .count_malformed, .low = "2", .high = std.fmt.comptimePrint("{d}", .{retention_capacity.entries}) },
        .{ .command = .host_serve, .name = "bash-timeout-ms", .code = .count_malformed, .low = "1", .high = "9223372036854775807" },
    };
    for (cases) |case| {
        var spelling: [64]u8 = undefined;
        const flag_name = try std.fmt.bufPrint(&spelling, "--{s}", .{case.name});
        for ([_][]const u8{ "12x", "-1", "+1", "1_0", "", "18446744073709551616" }) |invalid| {
            const refusal = try expectRefusal(case.command, &.{ flag_name, invalid }, case.code, case.name);
            try std.testing.expectEqualStrings(invalid, refusal.value.?);
            try std.testing.expect(std.mem.indexOf(u8, refusal.accepted.?.grammar, case.low) != null);
            try std.testing.expect(std.mem.indexOf(u8, refusal.accepted.?.grammar, case.high) != null);
        }
        if (!std.mem.eql(u8, case.low, "0")) _ = try expectRefusal(case.command, &.{ flag_name, "0" }, case.code, case.name);
        const upper = try std.fmt.parseInt(u64, case.high, 10);
        if (upper < std.math.maxInt(u64)) {
            var beyond: [32]u8 = undefined;
            _ = try expectRefusal(case.command, &.{ flag_name, try std.fmt.bufPrint(&beyond, "{d}", .{upper + 1}) }, case.code, case.name);
        }
        for ([_][]const u8{ case.low, case.high }) |valid| {
            var storage: [1024]u8 = undefined;
            _ = try testParse(case.command.definition(), &.{ flag_name, valid }, &storage);
        }
    }
}

test "fresh value validation can wait for the capture replay authority" {
    var refusal: Refusal = undefined;
    const definition = Command.session_configure.definition();
    const parsed = try definition.parseSyntax(&.{ "--record", "saved.json", "--key", "k", "--permission-mode", "historical-mode" }, std.testing.allocator, &refusal);
    try std.testing.expectEqualStrings("historical-mode", parsed.get("permission-mode").?);
    try std.testing.expectError(error.InvalidOptionValue, parsed.validateValues(&refusal));
    try std.testing.expectEqual(.choice_unsupported, refusal.code);
}

test "parser refusal golden lines cover the three invocation regressions" {
    const Case = struct { command: Command, args: []const []const u8, code: caller_error.Code, token: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .command = .session_start, .args = &.{ "--permission-mode", "auto" }, .code = .choice_unsupported, .token = "permission-mode", .expected = "rui session start: --permission-mode auto: That value is not supported. Accepted: ask, bypass. Next: Use one of the accepted values. Nothing was captured or sent. [choice_unsupported]\n" },
        .{ .command = .request_inspect, .args = &.{ "HANDLE", "--store", "P" }, .code = .handle_names_store_and_key, .token = "store", .expected = "rui request inspect: --store with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .command = .session_interrupt_model, .args = &.{ "--session", "k7m2qx", "--turn", "12x", "--operation", "3" }, .code = .id_malformed, .token = "turn", .expected = "rui session interrupt-model: --turn 12x: That is not an ID. Accepted: a decimal from 1 to 9223372036854775807. Next: Copy the ID from rui session inspect. Nothing was captured or sent. [id_malformed]\n" },
    };
    for (cases) |case| {
        const refusal = try expectRefusal(case.command, case.args, case.code, case.token);
        const definition = case.command.definition();
        var storage: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        try caller_error.writeLine(&out, refusal.code, refusal.held(@tagName(definition.resource), definition.name));
        try std.testing.expectEqualStrings(case.expected, out.buffered());
    }
}

// Literal lines pin each declared conflict's accepted grammar independently
// of the production catalog and table, including aliases and both orders.
test "conflict golden lines name every incompatible spelling and complete repair" {
    const Case = struct { command: Command, args: []const []const u8, code: caller_error.Code, token: []const u8, expected: []const u8 };
    const cases = [_]Case{
        .{ .command = .session_configure, .args = &.{ "--output-schema", "x", "--text-output" }, .code = .output_schema_excludes_text_output, .token = "output-schema", .expected = "rui session configure: --output-schema with --text-output: A schema and plain text output are alternative output modes. Accepted: --output-schema FILE or --text-output, not both. Next: Keep the desired output mode only. Nothing was captured or sent. [output_schema_excludes_text_output]\n" },
        .{ .command = .session_inspect, .args = &.{ "--profile", "x", "--failed-response", "x" }, .code = .profile_excludes_failed_response, .token = "profile", .expected = "rui session inspect: --profile with --failed-response: A Session report and a failed-response export are different inspections. Accepted: --profile PROFILE or --failed-response PART, not both. Next: Keep one inspection mode. Nothing was captured or sent. [profile_excludes_failed_response]\n" },
        .{ .command = .session_stop, .args = &.{ "--all", "--session", "x" }, .code = .all_excludes_session, .token = "all", .expected = "rui session stop: --all with --session: Stopping all Sessions excludes a single Session selector. Accepted: --all or --session ID, not both. Next: Keep --all or select one Session. Nothing was captured or sent. [all_excludes_session]\n" },
        .{ .command = .session_stop, .args = &.{ "--all", "--record", "x" }, .code = .all_excludes_record, .token = "all", .expected = "rui session stop: --all with --record: Stopping all Sessions creates a separate capture for each Session. Accepted: --all without --record, or --session ID with an explicit capture. Next: Remove --record or stop a single Session. Nothing was captured or sent. [all_excludes_record]\n" },
        .{ .command = .session_stop, .args = &.{ "--all", "--key", "x" }, .code = .all_excludes_key, .token = "all", .expected = "rui session stop: --all with --key: Stopping all Sessions creates a separate key for each Session. Accepted: --all without --key or --key-hex, or --session ID with an explicit capture. Next: Remove the explicit key or stop a single Session. Nothing was captured or sent. [all_excludes_key]\n" },
        .{ .command = .session_stop, .args = &.{ "--all", "--key-hex", "x" }, .code = .all_excludes_key, .token = "all", .expected = "rui session stop: --all with --key-hex: Stopping all Sessions creates a separate key for each Session. Accepted: --all without --key or --key-hex, or --session ID with an explicit capture. Next: Remove the explicit key or stop a single Session. Nothing was captured or sent. [all_excludes_key]\n" },
        .{ .command = .defaults_configure, .args = &.{ "--model", "x", "--clear-model" }, .code = .model_excludes_clear_model, .token = "model", .expected = "rui defaults configure: --model with --clear-model: Setting and clearing the saved model conflict. Accepted: --model MODEL or --clear-model, not both. Next: Keep the desired model change only. Nothing was captured or sent. [model_excludes_clear_model]\n" },
        .{ .command = .host_serve, .args = &.{ "--launch-frame", "--store", "x" }, .code = .launch_frame_excludes_store, .token = "launch-frame", .expected = "rui host serve: --launch-frame with --store: The launch frame already supplies the Store. Accepted: --launch-frame, or --store PATH or --store-hex HEX without --launch-frame. Next: Remove the Store flag or stop using --launch-frame. Nothing was captured or sent. [launch_frame_excludes_store]\n" },
        .{ .command = .host_serve, .args = &.{ "--launch-frame", "--store-hex", "x" }, .code = .launch_frame_excludes_store, .token = "launch-frame", .expected = "rui host serve: --launch-frame with --store-hex: The launch frame already supplies the Store. Accepted: --launch-frame, or --store PATH or --store-hex HEX without --launch-frame. Next: Remove the Store flag or stop using --launch-frame. Nothing was captured or sent. [launch_frame_excludes_store]\n" },
        .{ .command = .host_serve, .args = &.{ "--launch-frame", "--provider", "x" }, .code = .launch_frame_excludes_provider, .token = "launch-frame", .expected = "rui host serve: --launch-frame with --provider: A launch frame cannot be combined with a separate provider option. Accepted: --launch-frame without --provider, or --provider without --launch-frame. Next: Remove --provider or stop using --launch-frame. Nothing was captured or sent. [launch_frame_excludes_provider]\n" },
        .{ .command = .host_serve, .args = &.{ "--launch-frame", "--provider-endpoint", "x" }, .code = .launch_frame_excludes_provider_endpoint, .token = "launch-frame", .expected = "rui host serve: --launch-frame with --provider-endpoint: A launch frame cannot be combined with a separate provider endpoint option. Accepted: --launch-frame without --provider-endpoint, or --provider-endpoint without --launch-frame. Next: Remove --provider-endpoint or stop using --launch-frame. Nothing was captured or sent. [launch_frame_excludes_provider_endpoint]\n" },
        .{ .command = .host_serve, .args = &.{ "--launch-frame", "--provider-ca-file", "x" }, .code = .launch_frame_excludes_provider_ca_file, .token = "launch-frame", .expected = "rui host serve: --launch-frame with --provider-ca-file: A launch frame cannot be combined with a separate provider CA file option. Accepted: --launch-frame without --provider-ca-file, or --provider-ca-file without --launch-frame. Next: Remove --provider-ca-file or stop using --launch-frame. Nothing was captured or sent. [launch_frame_excludes_provider_ca_file]\n" },
        .{ .command = .host_serve, .args = &.{ "--launch-frame", "--active-capacity", "x" }, .code = .launch_frame_excludes_active_capacity, .token = "launch-frame", .expected = "rui host serve: --launch-frame with --active-capacity: A launch frame cannot be combined with a separate active capacity option. Accepted: --launch-frame without --active-capacity, or --active-capacity without --launch-frame. Next: Remove --active-capacity or stop using --launch-frame. Nothing was captured or sent. [launch_frame_excludes_active_capacity]\n" },
        .{ .command = .host_serve, .args = &.{ "--launch-frame", "--test-codex-fixture-endpoint", "x" }, .code = .launch_frame_excludes_codex_fixture, .token = "launch-frame", .expected = "rui host serve: --launch-frame with --test-codex-fixture-endpoint: A launch frame cannot be combined with a separate Codex fixture endpoint option. Accepted: --launch-frame without --test-codex-fixture-endpoint, or --test-codex-fixture-endpoint without --launch-frame. Next: Remove --test-codex-fixture-endpoint or stop using --launch-frame. Nothing was captured or sent. [launch_frame_excludes_codex_fixture]\n" },
        .{ .command = .host_serve, .args = &.{ "--launch-frame", "--test-openai-fixture-endpoint", "x" }, .code = .launch_frame_excludes_openai_fixture, .token = "launch-frame", .expected = "rui host serve: --launch-frame with --test-openai-fixture-endpoint: A launch frame cannot be combined with a separate OpenAI fixture endpoint option. Accepted: --launch-frame without --test-openai-fixture-endpoint, or --test-openai-fixture-endpoint without --launch-frame. Next: Remove --test-openai-fixture-endpoint or stop using --launch-frame. Nothing was captured or sent. [launch_frame_excludes_openai_fixture]\n" },
        .{ .command = .host_serve, .args = &.{ "--provider", "x", "--provider-endpoint", "x" }, .code = .provider_excludes_endpoint, .token = "provider", .expected = "rui host serve: --provider with --provider-endpoint: A managed provider and a development endpoint are alternative provider sources. Accepted: --provider LABEL or --provider-endpoint URL, not both. Next: Keep the managed provider or the development source, not both. Nothing was captured or sent. [provider_excludes_endpoint]\n" },
        .{ .command = .host_serve, .args = &.{ "--provider", "x", "--provider-ca-file", "x" }, .code = .provider_excludes_ca_file, .token = "provider", .expected = "rui host serve: --provider with --provider-ca-file: A managed provider cannot use a development endpoint CA file. Accepted: --provider LABEL, or --provider-endpoint URL with --provider-ca-file PATH. Next: Keep the managed provider or the development endpoint and its CA file. Nothing was captured or sent. [provider_excludes_ca_file]\n" },
        .{ .command = .host_serve, .args = &.{ "--provider", "x", "--test-codex-fixture-endpoint", "x" }, .code = .provider_excludes_codex_fixture, .token = "provider", .expected = "rui host serve: --provider with --test-codex-fixture-endpoint: A managed provider and a Codex fixture are alternative provider sources. Accepted: --provider LABEL or --test-codex-fixture-endpoint URL, not both. Next: Keep the managed provider or the development source, not both. Nothing was captured or sent. [provider_excludes_codex_fixture]\n" },
        .{ .command = .host_serve, .args = &.{ "--test-codex-fixture-endpoint", "x", "--provider-endpoint", "x" }, .code = .codex_fixture_excludes_endpoint, .token = "test-codex-fixture-endpoint", .expected = "rui host serve: --test-codex-fixture-endpoint with --provider-endpoint: A Codex fixture and a development endpoint are alternative provider sources. Accepted: --test-codex-fixture-endpoint URL or --provider-endpoint URL, not both. Next: Keep one endpoint source. Nothing was captured or sent. [codex_fixture_excludes_endpoint]\n" },
        .{ .command = .host_serve, .args = &.{ "--test-openai-fixture-endpoint", "x", "--provider-endpoint", "x" }, .code = .openai_fixture_excludes_endpoint, .token = "test-openai-fixture-endpoint", .expected = "rui host serve: --test-openai-fixture-endpoint with --provider-endpoint: An OpenAI fixture and a development endpoint are alternative provider sources. Accepted: --test-openai-fixture-endpoint URL or --provider-endpoint URL, not both. Next: Keep one endpoint source. Nothing was captured or sent. [openai_fixture_excludes_endpoint]\n" },
        .{ .command = .request_inspect, .args = &.{ "request-handle", "--store", "P" }, .code = .handle_names_store_and_key, .token = "store", .expected = "rui request inspect: --store with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .command = .request_inspect, .args = &.{ "request-handle", "--store-hex", "P" }, .code = .handle_names_store_and_key, .token = "store-hex", .expected = "rui request inspect: --store-hex with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .command = .request_inspect, .args = &.{ "request-handle", "--key", "P" }, .code = .handle_names_store_and_key, .token = "key", .expected = "rui request inspect: --key with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .command = .request_inspect, .args = &.{ "request-handle", "--key-hex", "P" }, .code = .handle_names_store_and_key, .token = "key-hex", .expected = "rui request inspect: --key-hex with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .command = .request_read_result, .args = &.{ "request-handle", "--store", "P" }, .code = .handle_names_store_and_key, .token = "store", .expected = "rui request read-result: --store with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .command = .request_read_result, .args = &.{ "request-handle", "--store-hex", "P" }, .code = .handle_names_store_and_key, .token = "store-hex", .expected = "rui request read-result: --store-hex with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .command = .request_read_result, .args = &.{ "request-handle", "--key", "P" }, .code = .handle_names_store_and_key, .token = "key", .expected = "rui request read-result: --key with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .command = .request_read_result, .args = &.{ "request-handle", "--key-hex", "P" }, .code = .handle_names_store_and_key, .token = "key-hex", .expected = "rui request read-result: --key-hex with HANDLE: A saved HANDLE already names its Store and key. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with (--key KEY or --key-hex HEX). Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_and_key]\n" },
        .{ .command = .request_recover, .args = &.{ "request-handle", "--store", "P" }, .code = .handle_names_store_record_and_kind, .token = "store", .expected = "rui request recover: --store with HANDLE: A saved HANDLE already names its Store, record and kind. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with --record FILE --kind KIND. Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_record_and_kind]\n" },
        .{ .command = .request_recover, .args = &.{ "request-handle", "--store-hex", "P" }, .code = .handle_names_store_record_and_kind, .token = "store-hex", .expected = "rui request recover: --store-hex with HANDLE: A saved HANDLE already names its Store, record and kind. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with --record FILE --kind KIND. Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_record_and_kind]\n" },
        .{ .command = .request_recover, .args = &.{ "request-handle", "--record", "P" }, .code = .handle_names_store_record_and_kind, .token = "record", .expected = "rui request recover: --record with HANDLE: A saved HANDLE already names its Store, record and kind. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with --record FILE --kind KIND. Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_record_and_kind]\n" },
        .{ .command = .request_recover, .args = &.{ "request-handle", "--kind", "P" }, .code = .handle_names_store_record_and_kind, .token = "kind", .expected = "rui request recover: --kind with HANDLE: A saved HANDLE already names its Store, record and kind. Accepted: HANDLE alone, or (--store PATH or --store-hex HEX) with --record FILE --kind KIND. Next: Keep one of the two. Nothing was captured or sent. [handle_names_store_record_and_kind]\n" },
        .{ .command = .session_resume, .args = &.{ "k7m2qx", "--session", "k7m2qx" }, .code = .session_selector_repeated, .token = "session", .expected = "rui session resume: --session with ID: The positional ID already names the Session. Accepted: ID alone, or --session ID. Next: Keep one Session selector. Nothing was captured or sent. [session_selector_repeated]\n" },
        .{ .command = .session_configure, .args = &.{ "--instructions", "-", "--output-schema", "-" }, .code = .stdin_sources_conflict, .token = "instructions", .expected = "rui session configure: --instructions with --output-schema: Instructions and the output schema cannot both read stdin. Accepted: --instructions - with --output-schema FILE, or --output-schema - without --instructions. Next: Read the schema from a file or supply instructions in a separate command. Nothing was captured or sent. [stdin_sources_conflict]\n" },
        .{ .command = .session_configure, .args = &.{ "--store", "61", "--store-hex", "61" }, .code = .identity_spelling_repeated, .token = "store", .expected = "rui session configure: --store with --store-hex: Both spellings name the same identity. Accepted: one spelling of the identity, plain or hex. Next: Keep the plain flag or its hex spelling, not both. Nothing was captured or sent. [identity_spelling_repeated]\n" },
        .{ .command = .session_configure, .args = &.{ "--store-hex", "61", "--store", "61" }, .code = .identity_spelling_repeated, .token = "store-hex", .expected = "rui session configure: --store-hex with --store: Both spellings name the same identity. Accepted: one spelling of the identity, plain or hex. Next: Keep the plain flag or its hex spelling, not both. Nothing was captured or sent. [identity_spelling_repeated]\n" },
        .{ .command = .session_configure, .args = &.{ "--key", "61", "--key-hex", "61" }, .code = .identity_spelling_repeated, .token = "key", .expected = "rui session configure: --key with --key-hex: Both spellings name the same identity. Accepted: one spelling of the identity, plain or hex. Next: Keep the plain flag or its hex spelling, not both. Nothing was captured or sent. [identity_spelling_repeated]\n" },
        .{ .command = .session_configure, .args = &.{ "--key-hex", "61", "--key", "61" }, .code = .identity_spelling_repeated, .token = "key-hex", .expected = "rui session configure: --key-hex with --key: Both spellings name the same identity. Accepted: one spelling of the identity, plain or hex. Next: Keep the plain flag or its hex spelling, not both. Nothing was captured or sent. [identity_spelling_repeated]\n" },
    };
    for (cases) |case| {
        const refusal = try expectRefusal(case.command, case.args, case.code, case.token);
        const definition = case.command.definition();
        var storage: [1024]u8 = undefined;
        var out = std.Io.Writer.fixed(&storage);
        try caller_error.writeLine(&out, refusal.code, refusal.held(@tagName(definition.resource), definition.name));
        try std.testing.expectEqualStrings(case.expected, out.buffered());
    }
}

test "Session IDs in positional argv name the missing selector flag" {
    _ = try expectRefusal(.session_send, &.{"v948er"}, .session_id_needs_to, "v948er");
    _ = try expectRefusal(.session_send, &.{ "v948er", "--store", "/s" }, .session_id_needs_to, "v948er");
    _ = try expectRefusal(.session_send, &.{ "v948er", "--to", "k7m2qx" }, .message_not_stdin, "v948er");
    _ = try expectRefusal(.session_send, &.{ "--to", "k7m2qx", "v948er" }, .message_not_stdin, "v948er");
    _ = try expectRefusal(.session_send, &.{ "--record", "--to", "v948er" }, .session_id_needs_to, "v948er");
    _ = try expectRefusal(.session_send, &.{"message text"}, .message_not_stdin, "message text");
    inline for (.{ Command.session_inspect, Command.session_stop, Command.session_archive, Command.session_unarchive, Command.session_interrupt_model, Command.session_read_conversation, Command.action_allow, Command.action_deny }) |command| {
        _ = try expectRefusal(command, &.{"v948er"}, .session_id_needs_session, "v948er");
    }
}

test "request wait accepts only one original identity and a bounded timeout" {
    try std.testing.expect(try expectMissing(.request_wait, &.{"HANDLE"}) == null);
    try std.testing.expect(try expectMissing(.request_wait, &.{ "--store", "PATH", "--key", "k" }) == null);
    try std.testing.expectEqualStrings("", (try expectMissing(.request_wait, &.{})).?);
    for ([_][]const u8{ "store", "store-hex", "key", "key-hex" }) |option| {
        var flag_buffer: [32]u8 = undefined;
        const flag_name = try std.fmt.bufPrint(&flag_buffer, "--{s}", .{option});
        _ = try expectRefusal(.request_wait, &.{ "HANDLE", flag_name, "P" }, .handle_names_store_and_key, option);
    }
    try expectValidation(.request_wait, &.{ "HANDLE", "--timeout-seconds", "1", "--timeout-seconds", "2" }, error.DuplicateArgument);
    try expectValidation(.request_wait, &.{ "HANDLE", "--since", "TOKEN" }, error.UnknownArgument);
    var storage: [1024]u8 = undefined;
    const parsed = try testParse(Command.request_wait.definition(), &.{ "HANDLE", "--timeout-seconds", "86400" }, &storage);
    try std.testing.expectEqual(@as(?u32, 86400), try parsed.number(u32, "timeout-seconds"));
}

test "archive commands require a Session and retain capture recovery options" {
    inline for (.{ Command.session_archive, Command.session_unarchive }) |command| {
        try std.testing.expect(try expectMissing(command, &.{}) != null);
        try std.testing.expect(try expectMissing(command, &.{ "--session", "k7m2qx" }) == null);
        try expectValidation(command, &.{ "--session", "k7m2qx", "--store", "/s", "--key", "key", "--record", "saved.json" }, false);
        try expectValidation(command, &.{ "--session", "k7m2qx", "--all" }, error.UnknownArgument);
    }
}

test "archive list visibility is independent of all Workspaces" {
    try expectValidation(.session_list, &.{ "--all", "--archived" }, false);
    try expectValidation(.session_list, &.{ "--all", "--include-archived" }, false);
    _ = try expectRefusal(.session_list, &.{ "--archived", "--include-archived" }, .archive_visibility_conflict, "archived");
}

// Pinned from the pre-table grammar: these expectations must not be derived.
test "Session settings CLI membership and order preserve configure and start" {
    inline for (.{
        .{ settings, &[_][]const u8{ "workspace", "instructions", "tools", "loaded-tools", "permission-mode", "output-schema", "text-output", "compaction-trigger", "output-reservation", "reasoning-effort", "label" } },
        .{ start_settings, &[_][]const u8{ "workspace", "tools", "loaded-tools", "permission-mode", "compaction-trigger", "output-reservation", "reasoning-effort", "label" } },
        .{ binding, &[_][]const u8{ "provider", "model" } },
    }) |case| {
        try std.testing.expectEqual(case[1].len, case[0].len);
        for (case[0], 0..) |option, index| try std.testing.expectEqualStrings(case[1][index], option.name);
    }
}

test "tool help lists every built-in including skill in name order" {
    for ([_]Command{ .session_configure, .session_start }) |command| {
        var help: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer help.deinit();
        try command.definition().help(&help.writer);
        try std.testing.expect(std.mem.indexOf(u8, help.written(), "--tools bash,find_tools,message_agent,read_transcript,skill,start_agent,web_search|none") != null);
    }
}
