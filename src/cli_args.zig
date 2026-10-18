//! Installed command grammar. Help and pre-effect syntax validation use the
//! same definitions; semantic values remain with the client/Store owners.
const std = @import("std");
const product_defaults = @import("product_defaults.zig");

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
            .session_send => .{ .resource = .session, .name = "send", .description = "Capture exact text and admit a Message to an already configured Session. Returns after admission, before the recipient completes. -- ends options; a dash after -- is literal.", .options = destination ++ session ++ capture ++ &[_]Option{value("text", "FILE|-")}, .positional = "TEXT|-", .mutation = true, .requires = need_session ++ &[_][]const []const u8{&.{ "text", "" }} },
            .session_inspect => .{ .resource = .session, .name = "inspect", .description = "Read current saved Session settings and work once as JSON. Inspection never admits work.", .options = destination ++ session ++ &[_]Option{value("profile", "current|full")}, .requires = need_session },
            .session_list => .{ .resource = .session, .name = "list", .description = "List configured Sessions in the current Workspace, or all Workspaces with --all, as one JSON value.", .options = destination ++ &[_]Option{flag("all")} },
            .session_stop => .{ .resource = .session, .name = "stop", .description = "Admit a stop for selected Session work. The address remains reusable by later input; acknowledgment is not physical retirement.", .options = destination ++ session ++ capture, .mutation = true, .requires = need_session },
            .session_interrupt_model => .{ .resource = .session, .name = "interrupt-model", .description = "Interrupt the exact model Operation after inspecting its Session and Turn.", .options = destination ++ session ++ capture ++ &[_]Option{ value("turn", "ID"), value("operation", "ID") }, .mutation = true, .requires = need_session ++ &[_][]const []const u8{ &.{"turn"}, &.{"operation"} } },
            .session_read_conversation => .{ .resource = .session, .name = "read-conversation", .description = "Stream the exact saved public Conversation content at position and ordinal.", .options = destination ++ session ++ &[_]Option{ value("position", "POSITION"), value("ordinal", "ORDINAL") }, .requires = need_session ++ &[_][]const []const u8{ &.{"position"}, &.{"ordinal"} } },
            .session_resume => .{ .resource = .session, .name = "resume", .description = "Open an existing Session in the live terminal frontend. Requires terminal input/output; starts or attaches to a managed Host. --last selects the newest Session created in this Workspace.", .options = destination ++ session ++ &[_]Option{flag("last")}, .positional = "REF", .requires = &.{&.{ "", "session", "session-hex", "last" }} },
            .request_inspect => .{ .resource = .request, .name = "inspect", .description = "Observe the original submitted command once. HANDLE loads its saved identity; --store and --key address it explicitly. Never transmits captured intent.", .options = destination ++ key, .positional = "HANDLE", .requires = &.{&.{ "", "key", "key-hex" }} },
            .request_recover => .{ .resource = .request, .name = "recover", .description = "Retransmit the original saved command and inputs. This may first admit work if the original never committed. Use HANDLE, or --store PATH --record FILE --kind KIND.", .options = destination ++ &[_]Option{ value("record", "FILE"), value("kind", "configure|message|session-stop|model-interruption|permission-decision") }, .positional = "HANDLE", .mutation = true, .requires = &.{&.{ "", "record" }} },
            .request_read_result => .{ .resource = .request, .name = "read-result", .description = "Stream only the originally bound saved answer, without waiting or substituting newer Session work. Use HANDLE or --store and --key.", .options = destination ++ key, .positional = "HANDLE", .requires = &.{&.{ "", "key", "key-hex" }} },
            .request_list => .{ .resource = .request, .name = "list", .description = "Enumerate local generated captures as JSON. This is not Store history or guaranteed correlation after all output from concurrent calls is lost." },
            .action_inspect => .{ .resource = .action, .name = "inspect", .description = "Read the exact saved Action proposal before allowing or denying it. Inspection grants nothing.", .options = destination ++ session ++ action, .requires = need_action },
            .action_allow => .{ .resource = .action, .name = "allow", .description = "Admit permission to run this exact inspected Action once; the Host revalidates its target.", .options = destination ++ session ++ action ++ capture, .mutation = true, .requires = need_action },
            .action_deny => .{ .resource = .action, .name = "deny", .description = "Admit denial of this exact inspected Action.", .options = destination ++ session ++ action ++ capture, .mutation = true, .requires = need_action },
            .action_read_call_id => .{ .resource = .action, .name = "read-call-id", .description = "Stream the exact saved Action call ID bytes.", .options = destination ++ session ++ action, .requires = need_action },
            .action_read_arguments => .{ .resource = .action, .name = "read-arguments", .description = "Stream the exact saved Action argument bytes.", .options = destination ++ session ++ action, .requires = need_action },
            .host_start => .{ .resource = .host, .name = "start", .description = std.fmt.comptimePrint("Explicitly start or connect to a managed Host. A new Host gets active capacity {d}; an already-running Host keeps its original settings, including capacity, as rui host status reports.", .{product_defaults.active_capacity}), .options = destination },
            .host_stop => .{ .resource = .host, .name = "stop", .description = "Request whole-Host shutdown, affecting every Session in this Store. Retry lost acknowledgment with the original --instance only; acknowledgment is not retirement.", .options = destination ++ &[_]Option{value("instance", "HEX")} },
            .host_status => .{ .resource = .host, .name = "status", .description = "Read protected Host readiness and capabilities without starting it.", .options = destination },
            .host_serve => .{ .resource = .host, .name = "serve", .description = std.fmt.comptimePrint("Run a foreground Host. Provider credentials belong to this Host, not its peer callers. Without --codex or a development endpoint it makes no model requests. --active-capacity defaults to {d}.", .{product_defaults.active_capacity}), .options = destination ++ &[_]Option{ value("active-capacity", "N"), flag("codex"), value("provider-endpoint", "URL"), value("provider-ca-file", "PATH"), value("bash-path", "PATH"), value("bash-timeout-ms", "MILLISECONDS") } },
            .defaults_inspect => .{ .resource = .defaults, .name = "inspect", .description = "Read future-Session defaults without writing preferences or changing Sessions." },
            .defaults_configure => .{ .resource = .defaults, .name = "configure", .description = "Save explicit future-Session defaults. Existing Sessions are unchanged. --clear-model removes only the saved model.", .options = destination ++ binding ++ &[_]Option{flag("clear-model")}, .requires = &.{&.{ "store", "store-hex", "provider", "model", "clear-model" }} },
            .auth_login => .{ .resource = .auth, .name = "login", .description = "Explicit operator sign-in: rui auth login codex. Ordinary peer calls never sign in or prompt.", .positional = "PROVIDER", .requires = &.{&.{""}} },
        };
    }
};

/// Shared by this help and the interactive /configure usage.
pub const compaction_policy =
    \\--compaction-trigger TOKENS|default sets a positive estimated context pressure threshold.
    \\--output-reservation TOKENS|default sets nonnegative extra compaction headroom, not a guaranteed output budget.
    \\Omission preserves an existing Session's setting; default resets it to model policy.
    \\Changes apply to new model requests. Requests already accepted keep their original settings, even when retried.
    \\Unknown models have no automatic threshold.
;

const compaction_help = compaction_policy ++
    \\ Inspect settings with rui session inspect.
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
const need_session = &[_][]const []const u8{&.{ "session", "session-hex" }};
const need_action = need_session ++ &[_][]const []const u8{&.{"action"}};

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
    /// Each group needs one of its alternatives; "" names the positional.
    requires: []const []const []const u8 = &.{},

    pub fn help(self: Definition, writer: *std.Io.Writer) !void {
        try writer.print("rui {s} {s}", .{ @tagName(self.resource), self.name });
        for (self.options) |option| {
            try writer.print(" [--{s}", .{option.name});
            if (option.argument) |argument| try writer.print(" {s}", .{argument});
            try writer.writeByte(']');
        }
        if (self.positional) |positional| try writer.print(" [{s}]", .{positional});
        try writer.print("\n{s}\n", .{self.description});
        if (self.requires.len != 0) {
            try writer.writeAll("Requires:");
            for (self.requires, 0..) |group, n| {
                try writer.writeAll(if (n == 0) " " else "; ");
                try self.writeGroup(writer, group);
            }
            try writer.writeAll(".\n");
        }
        if (self.mutation and self.optionNamed("record") != null and self.optionNamed("kind") == null)
            try writer.writeAll("Explicit capture uses --record FILE with --key KEY or --key-hex HEX; omit both for a generated handle.\n");
        try writer.writeAll(self.details);
        try writer.writeAll("--help or -h prints this help without accessing runtime state. Non-interactive metadata is one JSON value on stdout; explicit content reads stream bytes.\n");
        if (self.mutation and self.optionNamed("kind") == null) try writer.writeAll("Keep the pre-send recovery identity printed on stderr. Recover with rui request recover HANDLE, or --store PATH --record FILE --kind KIND. Nonzero exit can follow acceptance: inspect the original with rui request inspect; never infer permission to resubmit with a fresh key.\n");
    }

    /// Test-only options absent from help: null when `name` is not one.
    fn hiddenTakesValue(self: Definition, name: []const u8) ?bool {
        if (self.optionNamed(name) != null) return null;
        if (self.resource == .host and std.mem.eql(u8, self.name, "serve") and
            (std.mem.startsWith(u8, name, "test-") or std.mem.eql(u8, name, "fault"))) return !serveFlag(name);
        if (self.mutation and std.mem.eql(u8, name, "test-drop-reply")) return true;
        return null;
    }

    fn optionNamed(self: Definition, name: []const u8) ?Option {
        for (self.options) |option| if (std.mem.eql(u8, option.name, name)) return option;
        return null;
    }

    pub fn writeGroup(self: Definition, writer: *std.Io.Writer, group: []const []const u8) !void {
        for (group, 0..) |name, n| {
            if (n != 0) try writer.writeAll(" or ");
            if (name.len == 0) {
                try writer.writeAll(self.positional.?);
                continue;
            }
            try writer.print("--{s}", .{name});
            if (self.optionNamed(name).?.argument) |argument| try writer.print(" {s}", .{argument});
        }
    }

    /// The first unmet requirement of an otherwise valid invocation, including
    /// an explicit capture identity given only half. Help skips this check.
    pub fn missing(self: Definition, args: []const []const u8) ?[]const []const u8 {
        for (self.requires) |group| {
            if (!self.present(args, group)) return group;
        }
        const halves = [_][2][]const []const u8{
            .{ &.{"record"}, if (self.optionNamed("kind") != null) &.{"kind"} else &.{ "key", "key-hex" } },
            .{ &.{ "key", "key-hex" }, &.{"record"} },
            .{ &.{"kind"}, &.{"record"} },
            // Only recovery has --kind; its record form names no saved Store.
            .{ &.{"record"}, if (self.optionNamed("kind") != null) &.{ "store", "store-hex" } else &.{"record"} },
        };
        if (self.mutation) for (halves) |half| {
            if (self.optionNamed(half[0][0]) == null) continue;
            if (self.present(args, half[0]) and !self.present(args, half[1])) return half[1];
        };
        return null;
    }

    /// Whether a validated invocation names any of these options ("" is the
    /// positional). Option values and literal text are data, not names.
    fn present(self: Definition, args: []const []const u8, names: []const []const u8) bool {
        var index: usize = 0;
        var literal = false;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (!literal and std.mem.eql(u8, arg, "--")) {
                literal = true;
                continue;
            }
            const option = !literal and std.mem.startsWith(u8, arg, "--");
            for (names) |name| {
                if (name.len == 0 and !option) return true;
                if (option and name.len != 0 and std.mem.eql(u8, arg[2..], name)) return true;
            }
            if (option and (self.hiddenTakesValue(arg[2..]) orelse if (self.optionNamed(arg[2..])) |known| known.argument != null else false)) index += 1;
        }
        return false;
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
                if (!matched) if (self.hiddenTakesValue(name)) |takes_value| {
                    if (takes_value) {
                        index += 1;
                        if (index == args.len) return error.MissingArgumentValue;
                    }
                    matched = true;
                };
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

/// Former top-level commands and their resource-first replacements. They are
/// refused rather than read as a fresh conversation's prompt.
const retired_names = [_][2][]const u8{
    .{ "exec", "session configure|send" },                 .{ "follow", "request inspect" },                      .{ "wait-session", "session inspect" },
    .{ "result", "request read-result" },                  .{ "setup", "defaults inspect|configure" },            .{ "serve", "host serve" },
    .{ "login", "auth login" },                            .{ "configure", "session configure" },                 .{ "message", "session send" },
    .{ "inspect-session", "session inspect" },             .{ "sessions", "session list" },                       .{ "stop-session", "session stop" },
    .{ "interrupt-model", "session interrupt-model" },     .{ "read-conversation", "session read-conversation" }, .{ "resume", "session resume" },
    .{ "observe-command", "request inspect" },             .{ "recover", "request recover" },                     .{ "retry", "request recover" },
    .{ "read-result", "request read-result" },             .{ "requests", "request list" },                       .{ "inspect-action", "action inspect" },
    .{ "allow-action", "action allow" },                   .{ "deny-action", "action deny" },                     .{ "read-action-call-id", "action read-call-id" },
    .{ "read-action-arguments", "action read-arguments" },
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

test "complete syntax still names the first missing requirement" {
    const send = Command.session_send.definition();
    try std.testing.expectEqualStrings("session", send.missing(&.{"hi"}).?[0]);
    try std.testing.expectEqualStrings("text", send.missing(&.{ "--session", "a" }).?[0]);
    try std.testing.expect(send.missing(&.{ "--session", "a", "--", "--text" }) == null);
    // Option values are data: --session's value does not supply the text.
    try std.testing.expectEqualStrings("text", send.missing(&.{ "--session", "hi" }).?[0]);
    try std.testing.expectEqualStrings("record", send.missing(&.{ "--session", "a", "--key", "k", "hi" }).?[0]);
    try std.testing.expectEqualStrings("key", send.missing(&.{ "--session", "a", "--record", "r", "hi" }).?[0]);
    try std.testing.expect(send.missing(&.{ "--session", "a", "--test-drop-reply", "x" }) != null);
    const resume_definition = Command.session_resume.definition();
    try std.testing.expect(resume_definition.missing(&.{ "--store", "/s", "--last" }) == null);
    try std.testing.expect(resume_definition.missing(&.{ "--store", "/s" }) != null);
    const recover = Command.request_recover.definition();
    try std.testing.expect(recover.missing(&.{"HANDLE"}) == null);
    try std.testing.expectEqualStrings("kind", recover.missing(&.{ "--record", "r" }).?[0]);
    try std.testing.expect(Command.defaults_configure.definition().missing(&.{}) != null);
    try std.testing.expect(Command.session_configure.definition().missing(&.{}) == null);
    try std.testing.expectEqualStrings("defaults inspect|configure", retired("setup").?);
    try std.testing.expect(retired("session") == null and retired("fix the build") == null);
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
