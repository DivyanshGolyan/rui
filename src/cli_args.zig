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
            .session_configure => .{ .resource = .session, .name = "configure", .description = "Capture settings, then admit configuration only. Omit the Session selector to create a fresh address with concrete defaults; addressed changes preserve omitted settings.", .options = destination ++ session ++ capture ++ binding ++ &[_]Option{
                value("workspace", "PATH"), value("instructions", "FILE|-"), value("tools", "bash|edit|none"), value("permission-mode", "bypass|ask"), value("output-schema", "FILE|-"), flag("text-output"),
            }, .mutation = true },
            .session_send => .{ .resource = .session, .name = "send", .description = "Capture exact text and admit a Message to an already configured Session. Returns before recipient completion. -- ends options; a dash after -- is literal.", .options = destination ++ session ++ capture ++ &[_]Option{value("text", "FILE|-")}, .positional = "TEXT|-", .mutation = true },
            .session_inspect => .{ .resource = .session, .name = "inspect", .description = "Read current saved Session state once. Inspection never admits work.", .options = destination ++ session ++ &[_]Option{value("profile", "current|full")} },
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
            .host_serve => .{ .resource = .host, .name = "serve", .description = "Run a foreground Host. Provider credentials belong to this Host, not its peer callers.", .options = destination ++ &[_]Option{ value("active-capacity", "N"), flag("codex"), value("provider-endpoint", "URL"), value("provider-ca-file", "PATH"), value("bash-path", "PATH"), value("bash-timeout-ms", "MILLISECONDS") } },
            .defaults_inspect => .{ .resource = .defaults, .name = "inspect", .description = "Read future-Session defaults without writing preferences or changing Sessions." },
            .defaults_configure => .{ .resource = .defaults, .name = "configure", .description = "Save explicit future-Session defaults. Existing Sessions are unchanged.", .options = destination ++ binding ++ &[_]Option{flag("clear-model")} },
            .auth_login => .{ .resource = .auth, .name = "login", .description = "Explicit operator sign-in. Ordinary peer calls never sign in or prompt.", .positional = "codex" },
        };
    }
};

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

pub const Definition = struct {
    resource: Resource,
    name: []const u8,
    description: []const u8,
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
        try writer.writeAll("--help or -h prints this help without accessing runtime state. Non-interactive metadata is JSON; explicit content reads stream bytes.\n");
        if (self.mutation) try writer.writeAll("Keep the pre-send recovery identity. Recover with rui request recover HANDLE, or --store PATH --record FILE --kind KIND. Nonzero exit can follow acceptance: inspect the original key; never infer permission to resubmit with a fresh key.\n");
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
                    const no_value = std.mem.eql(u8, name, "test-phase-trace") or std.mem.eql(u8, name, "test-retention-removal-failure") or std.mem.eql(u8, name, "test-suppress-first-control-hint") or std.mem.eql(u8, name, "test-sqlite-diagnostics") or std.mem.eql(u8, name, "test-sqlite-cache-spill-off");
                    if (!no_value) {
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

pub fn resourceHelp(resource: Resource, writer: *std.Io.Writer) !void {
    try writer.print("rui {s} COMMAND\n", .{@tagName(resource)});
    inline for (std.meta.tags(Command)) |command| {
        const definition = command.definition();
        if (definition.resource == resource) try writer.print("  {s}: {s}\n", .{ definition.name, definition.description });
    }
    try writer.print("Use rui {s} COMMAND --help for options.\n", .{@tagName(resource)});
}

pub fn find(resource: Resource, name: []const u8) ?Command {
    inline for (std.meta.tags(Command)) |command| {
        const definition = command.definition();
        if (definition.resource == resource and std.mem.eql(u8, definition.name, name)) return command;
    }
    return null;
}
