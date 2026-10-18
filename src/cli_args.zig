//! Installed command grammar. Help and pre-effect syntax validation use the
//! same definitions; semantic values remain with the client/Store owners.
const std = @import("std");

pub const Resource = enum { session, request, action, host, defaults, auth };
pub const Command = enum {
    session_configure,
    session_send,
    session_inspect,
    session_list,
    session_stop,
    session_interrupt_model,
    session_read_conversation,
    session_resume,
    request_inspect,
    request_recover,
    request_read_result,
    request_list,
    action_inspect,
    action_allow,
    action_deny,
    action_read_call_id,
    action_read_arguments,
    host_start,
    host_stop,
    host_status,
    host_serve,
    defaults_inspect,
    defaults_configure,
    auth_login,

    pub fn definition(self: Command) Definition {
        // Option arrays have static storage, not a returned stack literal.
        return switch (self) {
            inline else => |command| comptime command.definitionValue(),
        };
    }

    fn definitionValue(self: Command) Definition {
        return switch (self) {
            .session_configure => .{ .resource = .session, .name = "configure", .description = "Capture settings, then admit configuration only. Omit the Session selector to create a fresh address with concrete defaults; addressed changes preserve omitted settings.", .details = compaction_help, .options = destination ++ session ++ capture ++ binding ++ &[_]Option{
                value("workspace", "PATH"),       value("instructions", "FILE|-"), value("tools", "bash|edit|none"),              value("permission-mode", "bypass|ask"),
                value("output-schema", "FILE|-"), flag("text-output"),             value("compaction-trigger", "TOKENS|default"), value("output-reservation", "TOKENS|default"),
            }, .mutation = true },
            .session_send => .{ .resource = .session, .name = "send", .description = "Capture exact text and admit a Message to an already configured Session. Returns after admission, before the recipient completes. -- ends options; a dash after -- is literal.", .options = destination ++ session ++ capture ++ &[_]Option{value("text", "FILE|-")}, .positional = "TEXT|-", .mutation = true },
            .session_inspect => .{ .resource = .session, .name = "inspect", .description = "Read current saved Session settings and work once as JSON. Inspection never admits work.", .options = destination ++ session ++ &[_]Option{value("profile", "current|full")} },
            .session_list => .{ .resource = .session, .name = "list", .description = "List configured Sessions in the current Workspace, or all Workspaces with --all, as one JSON value.", .options = destination ++ &[_]Option{flag("all")} },
            .session_stop => .{ .resource = .session, .name = "stop", .description = "Admit a stop for selected Session work. The address remains reusable by later input; acknowledgment is not physical retirement.", .options = destination ++ session ++ capture, .mutation = true },
            .session_interrupt_model => .{ .resource = .session, .name = "interrupt-model", .description = "Interrupt the exact model Operation after inspecting its Session and Turn.", .options = destination ++ session ++ capture ++ &[_]Option{ value("turn", "ID"), value("operation", "ID") }, .mutation = true },
            .session_read_conversation => .{ .resource = .session, .name = "read-conversation", .description = "Stream the exact saved public Conversation content at position and ordinal.", .options = destination ++ session ++ &[_]Option{ value("position", "POSITION"), value("ordinal", "ORDINAL") } },
            .session_resume => .{ .resource = .session, .name = "resume", .description = "Open an existing Session in the live terminal frontend. Requires terminal input/output; starts or attaches to a managed Host. --last selects the newest Session created in this Workspace.", .options = destination ++ session ++ &[_]Option{flag("last")}, .positional = "REF" },
            .request_inspect => .{ .resource = .request, .name = "inspect", .description = "Observe the original submitted command once. HANDLE loads its saved identity; --store and --key address it explicitly. Never transmits captured intent.", .options = destination ++ key, .positional = "HANDLE" },
            .request_recover => .{ .resource = .request, .name = "recover", .description = "Retransmit the original saved command and inputs. This may first admit work if the original never committed. Use HANDLE, or --store PATH --record FILE --kind KIND.", .options = destination ++ &[_]Option{ value("record", "FILE"), value("kind", "configure|message|session-stop|model-interruption|permission-decision") }, .positional = "HANDLE", .mutation = true },
            .request_read_result => .{ .resource = .request, .name = "read-result", .description = "Stream only the originally bound saved answer, without waiting or substituting newer Session work. Use HANDLE or --store and --key.", .options = destination ++ key, .positional = "HANDLE" },
            .request_list => .{ .resource = .request, .name = "list", .description = "Enumerate local generated captures as JSON. This is not Store history or guaranteed correlation after all output from concurrent calls is lost." },
            .action_inspect => .{ .resource = .action, .name = "inspect", .description = "Read the exact saved Action proposal before allowing or denying it. Inspection grants nothing.", .options = destination ++ session ++ action },
            .action_allow => .{ .resource = .action, .name = "allow", .description = "Admit permission to run this exact inspected Action once; the Host revalidates its target.", .options = destination ++ session ++ action ++ capture, .mutation = true },
            .action_deny => .{ .resource = .action, .name = "deny", .description = "Admit denial of this exact inspected Action.", .options = destination ++ session ++ action ++ capture, .mutation = true },
            .action_read_call_id => .{ .resource = .action, .name = "read-call-id", .description = "Stream the exact saved Action call ID bytes.", .options = destination ++ session ++ action },
            .action_read_arguments => .{ .resource = .action, .name = "read-arguments", .description = "Stream the exact saved Action argument bytes.", .options = destination ++ session ++ action },
            .host_start => .{ .resource = .host, .name = "start", .description = "Explicitly start or connect to a managed capacity-8 Host. Existing Host settings win.", .options = destination },
            .host_stop => .{ .resource = .host, .name = "stop", .description = "Request whole-Host shutdown, affecting every Session in this Store. Retry lost acknowledgment with the original --instance only; acknowledgment is not retirement.", .options = destination ++ &[_]Option{value("instance", "HEX")} },
            .host_status => .{ .resource = .host, .name = "status", .description = "Read protected Host readiness and capabilities without starting it.", .options = destination },
            .host_serve => .{ .resource = .host, .name = "serve", .description = "Run a foreground Host. Provider credentials belong to this Host, not its peer callers. Without --codex or a development endpoint it makes no model requests.", .options = destination ++ &[_]Option{ value("active-capacity", "N"), flag("codex"), value("provider-endpoint", "URL"), value("provider-ca-file", "PATH"), value("bash-path", "PATH"), value("bash-timeout-ms", "MILLISECONDS") } },
            .defaults_inspect => .{ .resource = .defaults, .name = "inspect", .description = "Read future-Session defaults without writing preferences or changing Sessions." },
            .defaults_configure => .{ .resource = .defaults, .name = "configure", .description = "Save explicit future-Session defaults. Existing Sessions are unchanged. --clear-model removes only the saved model.", .options = destination ++ binding ++ &[_]Option{flag("clear-model")} },
            .auth_login => .{ .resource = .auth, .name = "login", .description = "Explicit operator sign-in. Ordinary peer calls never sign in or prompt.", .positional = "codex" },
        };
    }
};

const compaction_help =
    \\--compaction-trigger TOKENS|default sets a positive estimated context pressure threshold.
    \\--output-reservation TOKENS|default sets nonnegative extra compaction headroom, not a guaranteed output budget.
    \\Omission preserves an existing Session's setting; default resets it to model policy.
    \\Changes apply to new model requests. Requests already accepted keep their original settings, even when retried.
    \\Unknown models have no automatic threshold. Inspect settings with rui session inspect.
    \\An unknown --session needs complete first configuration: --workspace PATH --provider codex --model MODEL.
    \\
;

const Option = struct { name: []const u8, argument: ?[]const u8 = null };
fn value(name: []const u8, argument: []const u8) Option {
    return .{ .name = name, .argument = argument };
}
fn flag(name: []const u8) Option {
    return .{ .name = name };
}
const destination = &[_]Option{ value("store", "PATH"), value("store-hex", "HEX") };
const session = &[_]Option{ value("session", "REF"), value("session-hex", "HEX") };
const key = &[_]Option{ value("key", "KEY"), value("key-hex", "HEX") };
const capture = &[_]Option{ value("record", "FILE"), value("key", "KEY"), value("key-hex", "HEX") };
const binding = &[_]Option{ value("provider", "codex"), value("model", "MODEL") };
const action = &[_]Option{value("action", "ID")};

/// Exact-identity selectors whose hex spelling carries bytes argv cannot.
pub const hex_selectors = [_][2][]const u8{ .{ "store-hex", "store" }, .{ "session-hex", "session" }, .{ "key-hex", "key" } };

pub const Definition = struct {
    resource: Resource,
    name: []const u8,
    description: []const u8,
    details: []const u8 = "",
    options: []const Option = &.{},
    positional: ?[]const u8 = null,
    mutation: bool = false,

    pub fn help(self: Definition, writer: *std.Io.Writer) !void {
        try writer.print("rui {s} {s}", .{ @tagName(self.resource), self.name });
        for (self.options) |option| {
            try writer.print(" [--{s}", .{option.name});
            if (option.argument) |argument| try writer.print(" {s}", .{argument});
            try writer.writeByte(']');
        }
        if (self.positional) |positional| try writer.print(" [{s}]", .{positional});
        try writer.print("\n{s}\n", .{self.description});
        try writer.writeAll(self.details);
        try writer.writeAll("--help or -h prints this help without accessing runtime state. Non-interactive metadata is one JSON value on stdout; explicit content reads stream bytes.\n");
        if (self.mutation) try writer.writeAll("Keep the pre-send recovery identity printed on stderr. Recover with rui request recover HANDLE, or --store PATH --record FILE --kind KIND. Nonzero exit can follow acceptance: inspect the original with rui request inspect; never infer permission to resubmit with a fresh key.\n");
    }

    /// Validate the whole invocation before any capture or environment access.
    /// Values are consumed before interpreting help; `--model --help` is data.
    /// Semantic decoding remains in each operation's handler.
    pub fn validate(self: Definition, args: []const []const u8) !bool {
        var seen: u64 = 0;
        var positional = false;
        var literal = false;
        var help_requested = false;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (!literal and std.mem.eql(u8, arg, "--")) {
                literal = true;
                continue;
            }
            if (!literal and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
                help_requested = true;
                continue;
            }
            if (!literal and std.mem.startsWith(u8, arg, "--")) {
                const name = arg[2..];
                var matched = false;
                for (self.options, 0..) |option, n| {
                    if (!std.mem.eql(u8, name, option.name)) continue;
                    const bit = @as(u64, 1) << @as(u6, @intCast(n));
                    if (seen & bit != 0) return error.DuplicateArgument;
                    seen |= bit;
                    if (option.argument != null) {
                        index += 1;
                        if (index == args.len) return error.MissingArgumentValue;
                    }
                    matched = true;
                    break;
                }
                // Fault injection is consumed by the existing owning handlers;
                // it is deliberately absent from installed capability help.
                if (!matched and self.resource == .host and std.mem.eql(u8, self.name, "serve") and
                    (std.mem.startsWith(u8, name, "test-") or std.mem.eql(u8, name, "fault")))
                {
                    if (!serveFlag(name)) {
                        index += 1;
                        if (index == args.len) return error.MissingArgumentValue;
                    }
                    matched = true;
                }
                if (!matched and self.mutation and std.mem.eql(u8, name, "test-drop-reply")) {
                    index += 1;
                    if (index == args.len) return error.MissingArgumentValue;
                    matched = true;
                }
                if (!matched) return error.UnknownArgument;
            } else {
                if (self.positional == null or positional or (!literal and arg.len > 1 and arg[0] == '-')) return error.InvalidArguments;
                positional = true;
            }
        }
        const pairs = [_][2][]const u8{ .{ "store", "store-hex" }, .{ "session", "session-hex" }, .{ "key", "key-hex" }, .{ "output-schema", "text-output" }, .{ "model", "clear-model" } };
        for (pairs) |pair| {
            var found: usize = 0;
            for (self.options, 0..) |option, n| {
                if (seen & (@as(u64, 1) << @as(u6, @intCast(n))) != 0 and (std.mem.eql(u8, option.name, pair[0]) or std.mem.eql(u8, option.name, pair[1]))) found += 1;
            }
            if (found == 2) return error.ConflictingArguments;
        }
        if (positional) for (self.options, 0..) |option, n| {
            if (seen & (@as(u64, 1) << @as(u6, @intCast(n))) == 0) continue;
            for ([_][]const u8{ "text", "session", "session-hex", "last", "key", "key-hex", "record", "kind", "store", "store-hex" }) |conflict| {
                if (!std.mem.eql(u8, option.name, conflict)) continue;
                const request = self.resource == .request;
                const resuming = self.resource == .session and std.mem.eql(u8, self.name, "resume");
                if (request or std.mem.eql(u8, conflict, "text") or (resuming and !std.mem.startsWith(u8, conflict, "store"))) return error.ConflictingArguments;
            }
        };
        return help_requested;
    }
};

fn serveFlag(name: []const u8) bool {
    for ([_][]const u8{ "test-phase-trace", "test-retention-removal-failure", "test-suppress-first-control-hint", "test-sqlite-diagnostics", "test-sqlite-cache-spill-off" }) |known| {
        if (std.mem.eql(u8, name, known)) return true;
    }
    return false;
}

pub fn resourceHelp(resource: Resource, writer: *std.Io.Writer) !void {
    try writer.print("rui {s} COMMAND\n", .{@tagName(resource)});
    inline for (comptime std.meta.tags(Command)) |command| {
        const definition = command.definition();
        if (definition.resource == resource) try writer.print("  {s}: {s}\n", .{ definition.name, definition.description });
    }
    try writer.print("Use rui {s} COMMAND --help for options.\n", .{@tagName(resource)});
}

pub fn find(resource: Resource, name: []const u8) ?Command {
    inline for (comptime std.meta.tags(Command)) |command| {
        const definition = command.definition();
        if (definition.resource == resource and std.mem.eql(u8, definition.name, name)) return command;
    }
    return null;
}

fn expectValidation(command: Command, args: []const []const u8, expected: anyerror!bool) !void {
    try std.testing.expectEqual(expected, command.definition().validate(args));
}

test "grammar rejects ambiguous invocations before any effect" {
    try expectValidation(.session_send, &.{ "--session", "a", "--session", "a", "hi" }, error.DuplicateArgument);
    try expectValidation(.session_send, &.{ "--session", "a", "--text", "f", "hi" }, error.ConflictingArguments);
    try expectValidation(.session_send, &.{ "--session", "a", "hi", "again" }, error.InvalidArguments);
    try expectValidation(.session_send, &.{ "--session", "a", "--bogus" }, error.UnknownArgument);
    try expectValidation(.session_send, &.{ "--session", "a", "--store", "/s", "--store-hex", "2f" }, error.ConflictingArguments);
    try expectValidation(.session_send, &.{"--session"}, error.MissingArgumentValue);
    try expectValidation(.session_configure, &.{ "--output-schema", "f", "--text-output" }, error.ConflictingArguments);
    try expectValidation(.defaults_configure, &.{ "--model", "m", "--clear-model" }, error.ConflictingArguments);
    try expectValidation(.request_inspect, &.{ "--key", "k", "HANDLE" }, error.ConflictingArguments);
    try expectValidation(.session_list, &.{"--json"}, error.UnknownArgument);
    // Values are data: an option value spelling --help does not request help,
    // and literal text after -- may look like an option or a dash.
    try expectValidation(.session_send, &.{ "--session", "--help", "--", "--help" }, false);
    try expectValidation(.session_send, &.{ "--session", "a", "--", "-" }, false);
    try expectValidation(.session_send, &.{ "--session", "a", "-" }, false);
    try expectValidation(.session_send, &.{ "--session", "a", "--help" }, true);
    try expectValidation(.session_resume, &.{ "--store", "/s", "REF" }, false);
    try expectValidation(.session_resume, &.{ "--session", "a", "REF" }, error.ConflictingArguments);
    try expectValidation(.host_serve, &.{ "--test-phase-trace", "--fault", "before-commit", "--codex" }, false);
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
