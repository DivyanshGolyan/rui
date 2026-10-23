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
            .session_configure => .{ .resource = .session, .name = "configure", .description = "Capture settings, then admit configuration only. Omit the Session selector to create a fresh address with concrete defaults; addressed changes preserve omitted settings.", .details = compaction_help, .options = destination ++ session ++ capture ++ binding ++ settings, .conflicts = settings_conflicts, .mutation = true },
            .session_send => .{ .resource = .session, .name = "send", .description = "Capture exact text and admit a Message to an already configured Session. Returns after admission, before the recipient completes. -- ends options; a dash after -- is literal.", .options = destination ++ session ++ capture ++ &[_]Option{value("text", "FILE|-")}, .positional = "TEXT|-", .positional_conflicts = &.{"text"}, .mutation = true, .requires = need_session ++ &[_][]const []const u8{&.{ "text", "" }} },
            .session_inspect => .{ .resource = .session, .name = "inspect", .description = "Read saved Session settings and work as JSON, or export exact retained failed-response bytes. Inspection never admits work.", .details = "--failed-response body|metadata requires --operation ID and --attempt N, excludes --profile, and writes only that stored byte stream to stdout. Redirect body output to a file; it can contain binary or private data. Missing records or omitted bodies fail on stderr. Partial bodies export their retained prefix; inspect metadata for status. No Host is started and no provider is contacted.\n", .options = destination ++ session ++ &[_]Option{ value("profile", "current|full"), value("failed-response", "body|metadata"), value("operation", "ID"), value("attempt", "N") }, .conflicts = &.{.{ "profile", "failed-response" }}, .requires = need_session },
            .session_list => .{ .resource = .session, .name = "list", .description = "List configured Sessions in the current Workspace, or all Workspaces with --all, as one JSON value.", .options = destination ++ &[_]Option{flag("all")} },
            .session_stop => .{ .resource = .session, .name = "stop", .description = "Admit a stop for selected Session work. The address remains reusable by later input; acknowledgment is not physical retirement.", .options = destination ++ session ++ capture, .mutation = true, .requires = need_session },
            .session_interrupt_model => .{ .resource = .session, .name = "interrupt-model", .description = "Interrupt the exact model Operation after inspecting its Session and Turn.", .options = destination ++ session ++ capture ++ &[_]Option{ value("turn", "ID"), value("operation", "ID") }, .mutation = true, .requires = need_session ++ &[_][]const []const u8{ &.{"turn"}, &.{"operation"} } },
            .session_read_conversation => .{ .resource = .session, .name = "read-conversation", .description = "Stream the exact saved public Conversation content at position and ordinal.", .options = destination ++ session ++ &[_]Option{ value("position", "POSITION"), value("ordinal", "ORDINAL") }, .requires = need_session ++ &[_][]const []const u8{ &.{"position"}, &.{"ordinal"} } },
            .session_resume => .{ .resource = .session, .name = "resume", .description = "Open an existing Session in the live terminal frontend. Requires terminal input/output; starts or attaches to a managed Host. --last selects the newest Session created in this Workspace.", .options = destination ++ session ++ &[_]Option{flag("last")}, .positional = "REF", .conflicts = &.{ .{ "session", "last" }, .{ "session-hex", "last" } }, .positional_conflicts = &.{ "session", "session-hex", "last" }, .requires = &.{&.{ "", "session", "session-hex", "last" }} },
            .request_inspect => .{ .resource = .request, .name = "inspect", .description = "Observe the original submitted command once. HANDLE loads its saved identity; --store and --key address it explicitly. Never transmits captured intent.", .options = destination ++ key, .positional = "HANDLE", .positional_conflicts = saved_identity, .requires = &.{&.{ "", "key", "key-hex" }} },
            .request_recover => .{ .resource = .request, .name = "recover", .description = "Retransmit the original saved command and inputs. This may first admit work if the original never committed. Use HANDLE, or --store PATH --record FILE --kind KIND.", .options = destination ++ &[_]Option{ value("record", "FILE"), value("kind", "configure|message|session-stop|model-interruption|permission-decision") }, .positional = "HANDLE", .positional_conflicts = &.{ "store", "store-hex", "record", "kind" }, .mutation = true, .requires = &.{&.{ "", "record" }} },
            .request_read_result => .{ .resource = .request, .name = "read-result", .description = "Stream only the originally bound saved answer, without waiting or substituting newer Session work. Use HANDLE or --store and --key.", .options = destination ++ key, .positional = "HANDLE", .positional_conflicts = saved_identity, .requires = &.{&.{ "", "key", "key-hex" }} },
            .request_list => .{ .resource = .request, .name = "list", .description = "Enumerate local generated captures as JSON. This is not Store history or guaranteed correlation after all output from concurrent calls is lost." },
            .action_inspect => .{ .resource = .action, .name = "inspect", .description = "Read the exact saved Action proposal before allowing or denying it. Inspection grants nothing.", .options = destination ++ session ++ action, .requires = need_action },
            .action_allow => .{ .resource = .action, .name = "allow", .description = "Admit permission to run this exact inspected Action once; the Host revalidates its target.", .options = destination ++ session ++ action ++ capture, .mutation = true, .requires = need_action },
            .action_deny => .{ .resource = .action, .name = "deny", .description = "Admit denial of this exact inspected Action.", .options = destination ++ session ++ action ++ capture, .mutation = true, .requires = need_action },
            .action_read_call_id => .{ .resource = .action, .name = "read-call-id", .description = "Stream the exact saved Action call ID bytes.", .options = destination ++ session ++ action, .requires = need_action },
            .action_read_arguments => .{ .resource = .action, .name = "read-arguments", .description = "Stream the exact saved Action argument bytes.", .options = destination ++ session ++ action, .requires = need_action },
            .host_start => .{ .resource = .host, .name = "start", .description = std.fmt.comptimePrint("Explicitly start or connect to a managed Host. A new Host gets active capacity {d}; an already-running Host keeps its original settings, including capacity, as rui host status reports.", .{product_defaults.active_capacity}), .options = destination },
            .host_stop => .{ .resource = .host, .name = "stop", .description = "Request whole-Host shutdown, affecting every Session in this Store. Retry lost acknowledgment with the original --instance only; acknowledgment is not retirement.", .options = destination ++ &[_]Option{value("instance", "HEX")} },
            .host_status => .{ .resource = .host, .name = "status", .description = "Read protected Host readiness and capabilities without starting it.", .options = destination },
            .host_serve => .{ .resource = .host, .name = "serve", .description = std.fmt.comptimePrint("Run a foreground Host. Provider credentials belong to this Host, not its peer callers. Without --codex or a development endpoint it makes no model requests. --active-capacity defaults to {d}.", .{product_defaults.active_capacity}), .options = destination ++ &[_]Option{ value("active-capacity", "N"), flag("codex"), value("provider-endpoint", "URL"), value("provider-ca-file", "PATH"), value("bash-path", "PATH"), value("bash-timeout-ms", "MILLISECONDS") } ++ serve_test, .conflicts = endpoint_conflicts },
            .defaults_inspect => .{ .resource = .defaults, .name = "inspect", .description = "Read future-Session defaults without writing preferences or changing Sessions." },
            .defaults_configure => .{ .resource = .defaults, .name = "configure", .description = "Save explicit future-Session defaults. Existing Sessions are unchanged. --clear-model removes only the saved model.", .options = destination ++ binding ++ &[_]Option{flag("clear-model")}, .conflicts = &.{.{ "model", "clear-model" }}, .requires = &.{&.{ "store", "store-hex", "provider", "model", "clear-model" }} },
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
++ product_defaults.model_help ++ "These release-supported IDs do not guarantee account availability or live qualification.\n";

const Option = struct {
    name: []const u8,
    argument: ?[]const u8 = null,
    /// A hex spelling of this exact-identity option's bytes, which argv cannot
    /// carry. Both spellings fill the named option; giving both conflicts.
    hex_of: ?[]const u8 = null,
    /// The identity's byte bound; `cli.zig` pins each to its protocol bound.
    hex_limit: usize = 0,
    /// Test-only: accepted by its owning operation but absent from help.
    hidden: bool = false,
    /// Accepted more than once; Parsed.all yields every value in order.
    repeated: bool = false,
};
fn value(name: []const u8, argument: []const u8) Option {
    return .{ .name = name, .argument = argument };
}
fn flag(name: []const u8) Option {
    return .{ .name = name };
}
fn hex(name: []const u8, of: []const u8, limit: usize) Option {
    return .{ .name = name, .argument = "HEX", .hex_of = of, .hex_limit = limit };
}
fn hiddenValue(name: []const u8) Option {
    return .{ .name = name, .argument = "VALUE", .hidden = true };
}
fn hiddenFlag(name: []const u8) Option {
    return .{ .name = name, .hidden = true };
}
const destination = &[_]Option{ value("store", "PATH"), hex("store-hex", "store", 492) };
const session = &[_]Option{ value("session", "REF"), hex("session-hex", "session", 128) };
const key = &[_]Option{ value("key", "KEY"), hex("key-hex", "key", 128) };
const capture = &[_]Option{ value("record", "FILE"), value("key", "KEY"), hex("key-hex", "key", 128), hiddenValue("test-drop-reply") };
const binding = &[_]Option{ value("provider", "codex"), value("model", "MODEL") };
const action = &[_]Option{value("action", "ID")};
const need_session = &[_][]const []const u8{&.{ "session", "session-hex" }};
const need_action = need_session ++ &[_][]const []const u8{&.{"action"}};
/// A saved request HANDLE names its own Store and key.
const saved_identity = &[_][]const u8{ "store", "store-hex", "key", "key-hex" };
/// Session settings shared by `session configure` and the live /configure.
const settings = &[_]Option{
    value("workspace", "PATH"),       value("instructions", "FILE|-"), value("tools", "bash|none"),                   value("permission-mode", "bypass|ask"),
    value("output-schema", "FILE|-"), flag("text-output"),             value("compaction-trigger", "TOKENS|default"), value("output-reservation", "TOKENS|default"),
};
const settings_conflicts = &[_][2][]const u8{.{ "output-schema", "text-output" }};
/// The managed endpoint and development endpoints are exclusive.
const endpoint_conflicts = &[_][2][]const u8{
    .{ "codex", "provider-endpoint" },
    .{ "codex", "provider-ca-file" },
    .{ "codex", "test-codex-fixture-endpoint" },
    .{ "test-codex-fixture-endpoint", "provider-endpoint" },
};
/// Host fault injection and observation, consumed only by host serve.
const serve_test = &[_]Option{
    .{ .name = "fault", .argument = "VALUE", .hidden = true, .repeated = true },
    hiddenValue("test-codex-fixture-endpoint"),
    hiddenValue("test-bash-scratch-limit-bytes"),
    hiddenValue("test-retention-entry-capacity"),
    hiddenFlag("test-retention-removal-failure"),
    hiddenValue("test-provider-inactivity-seconds"),
    hiddenValue("test-retry-waits-ms"),
    hiddenValue("test-before-launch-delay-ms"),
    hiddenValue("test-before-result-delay-ms"),
    hiddenValue("test-model-result-gate-path"),
    hiddenValue("test-retry-recovery-gate-path"),
    hiddenValue("test-inspection-reply-gate-path"),
    hiddenValue("test-inspection-reply-delay-ms"),
    hiddenValue("test-client-send-buffer-bytes"),
    hiddenFlag("test-phase-trace"),
    hiddenValue("test-observation-fd"),
    hiddenValue("test-observation-state-fd"),
    hiddenValue("test-observation-plan"),
    hiddenValue("test-transition"),
    hiddenValue("test-transition-gate-path"),
    hiddenValue("test-response-capture-gate-path"),
    hiddenValue("test-response-capture-gate-min-written-bytes"),
    hiddenValue("test-bash-observed-exit-gate-path"),
    hiddenValue("test-bash-cleanup-gate-path"),
    hiddenValue("test-control-gate-keys"),
    hiddenValue("test-control-gate-path"),
    hiddenFlag("test-suppress-first-control-hint"),
    hiddenFlag("test-sqlite-diagnostics"),
    hiddenFlag("test-sqlite-cache-spill-off"),
    hiddenValue("test-sqlite-cache-kib"),
    hiddenValue("test-request-scratch-limit"),
    hiddenValue("test-request-preparation-byte-allowance"),
    hiddenValue("test-request-preparation-item-allowance"),
    hiddenValue("test-request-preparation-advance-delay-ms"),
};

/// The bare `rui [PROMPT]` entry, which has no resource help of its own.
pub const fresh_session: Definition = .{ .resource = .session, .name = "", .description = "", .options = &.{ value("store", "PATH"), binding[0], binding[1] }, .positional = "PROMPT" };
/// The live Session's /configure: settings only; the Session is its address.
pub const live_configure: Definition = .{ .resource = .session, .name = "/configure", .description = "", .options = binding ++ settings, .conflicts = settings_conflicts };
/// The live Session's /setup: the defaults grammar, where none means inspect.
pub const live_setup: Definition = .{ .resource = .defaults, .name = "/setup", .description = "", .options = &.{ value("store", "PATH"), binding[0], binding[1], flag("clear-model") }, .conflicts = &.{.{ "model", "clear-model" }} };

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
    /// Option pairs an invocation may not combine.
    conflicts: []const [2][]const u8 = &.{},
    /// Options an invocation may not combine with the positional.
    positional_conflicts: []const []const u8 = &.{},

    pub fn help(self: Definition, writer: *std.Io.Writer) !void {
        try writer.print("rui {s} {s}", .{ @tagName(self.resource), self.name });
        for (self.options) |option| {
            if (option.hidden) continue;
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

    fn optionNamed(self: Definition, name: []const u8) ?Option {
        return self.options[self.indexOf(name) orelse return null];
    }

    fn indexOf(self: Definition, name: []const u8) ?usize {
        for (self.options, 0..) |option, n| if (std.mem.eql(u8, option.name, name)) return n;
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

    /// Parse the whole invocation before any capture or environment access.
    /// Values are consumed before interpreting help; `--model --help` is data.
    /// Hex spellings decode into their named option, through `allocator`,
    /// unless help is requested. Semantic decoding stays with each handler.
    pub fn parse(self: Definition, args: []const []const u8, allocator: std.mem.Allocator) Error!Parsed {
        var parsed: Parsed = .{ .definition = self };
        var hexed: u64 = 0;
        var literal = false;
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (!literal and std.mem.eql(u8, arg, "--")) {
                literal = true;
                continue;
            }
            if (!literal and (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h"))) {
                parsed.help = true;
                continue;
            }
            if (literal or !std.mem.startsWith(u8, arg, "--")) {
                if (self.positional == null or parsed.positional != null or (!literal and arg.len > 1 and arg[0] == '-')) return error.InvalidArguments;
                parsed.positional = arg;
                parsed.literal_positional = literal;
                continue;
            }
            const n = self.indexOf(arg[2..]) orelse return error.UnknownArgument;
            const option = self.options[n];
            const bit = @as(u64, 1) << @as(u6, @intCast(n));
            if (parsed.seen & bit != 0 and !option.repeated) return error.DuplicateArgument;
            parsed.seen |= bit;
            if (option.argument == null) continue;
            index += 1;
            if (index == args.len) return error.MissingArgumentValue;
            if (option.repeated) {
                if (parsed.repeat_count == parsed.repeats.len) return error.DuplicateArgument;
                parsed.repeats[parsed.repeat_count] = args[index];
                parsed.repeat_count += 1;
                continue;
            }
            // Both spellings of one identity fill the same value.
            const slot = if (option.hex_of) |named| self.indexOf(named).? else n;
            if (parsed.values[slot] != null) return error.ConflictingArguments;
            parsed.values[slot] = args[index];
            if (option.hex_of != null) hexed |= @as(u64, 1) << @as(u6, @intCast(slot));
        }
        for (self.conflicts) |pair| if (parsed.has(pair[0]) and parsed.has(pair[1])) return error.ConflictingArguments;
        if (parsed.positional != null) for (self.positional_conflicts) |name| if (parsed.has(name)) return error.ConflictingArguments;
        if (parsed.help) return parsed;
        for (self.options) |option| {
            const named = self.indexOf(option.hex_of orelse continue).?;
            if (hexed & (@as(u64, 1) << @as(u6, @intCast(named))) == 0) continue;
            parsed.values[named] = try decodeHex(allocator, parsed.values[named].?, option.hex_limit);
        }
        return parsed;
    }

    pub const Error = error{ DuplicateArgument, UnknownArgument, MissingArgumentValue, ConflictingArguments, InvalidArguments, InvalidHexIdentity, OutOfMemory };
};

fn decodeHex(allocator: std.mem.Allocator, encoded: []const u8, limit: usize) ![]const u8 {
    if (encoded.len == 0 or encoded.len % 2 != 0 or encoded.len / 2 > limit) return error.InvalidHexIdentity;
    const bytes = try allocator.alloc(u8, encoded.len / 2);
    const decoded = std.fmt.hexToBytes(bytes, encoded) catch return error.InvalidHexIdentity;
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.InvalidHexIdentity;
    return decoded;
}

/// One invocation's values, keyed by option name. Handlers read these; none
/// walks argv again.
pub const Parsed = struct {
    definition: Definition,
    /// Each option's value by index; a hex spelling fills its named option.
    values: [64]?[]const u8 = @splat(null),
    /// Options spelled in the invocation, by index.
    seen: u64 = 0,
    repeats: [16][]const u8 = undefined,
    repeat_count: usize = 0,
    positional: ?[]const u8 = null,
    /// The positional followed `--`, so a lone dash is literal text.
    literal_positional: bool = false,
    help: bool = false,

    /// The value of `name` in either spelling; null when not given or not
    /// part of this grammar.
    pub fn get(self: *const Parsed, name: []const u8) ?[]const u8 {
        return self.values[self.definition.indexOf(name) orelse return null];
    }

    /// Whether the invocation spelled `name` ("" is the positional).
    pub fn has(self: *const Parsed, name: []const u8) bool {
        if (name.len == 0) return self.positional != null;
        const n = self.definition.indexOf(name) orelse return false;
        return self.seen & (@as(u64, 1) << @as(u6, @intCast(n))) != 0;
    }

    /// Every value of the repeatable option, in order.
    pub fn all(self: *const Parsed, name: []const u8) []const []const u8 {
        const option = self.definition.optionNamed(name) orelse return &.{};
        return if (option.repeated) self.repeats[0..self.repeat_count] else &.{};
    }

    /// A decimal value of `name`, when given.
    pub fn number(self: *const Parsed, comptime T: type, name: []const u8) !?T {
        return try std.fmt.parseInt(T, self.get(name) orelse return null, 10);
    }

    fn any(self: *const Parsed, names: []const []const u8) bool {
        for (names) |name| if (self.has(name)) return true;
        return false;
    }

    /// The first unmet requirement of a parsed invocation, including an
    /// explicit capture identity given only half. Help skips this check.
    pub fn missing(self: *const Parsed) ?[]const []const u8 {
        const definition = self.definition;
        for (definition.requires) |group| {
            if (!self.any(group)) return group;
        }
        const recovery = definition.optionNamed("kind") != null;
        const halves = [_][2][]const []const u8{
            .{ &.{"record"}, if (recovery) &.{"kind"} else &.{ "key", "key-hex" } },
            .{ &.{ "key", "key-hex" }, &.{"record"} },
            .{ &.{"kind"}, &.{"record"} },
            // Only recovery has --kind; its record form names no saved Store.
            .{ &.{"record"}, if (recovery) &.{ "store", "store-hex" } else &.{"record"} },
        };
        if (definition.mutation) for (halves) |half| {
            if (definition.optionNamed(half[0][0]) == null) continue;
            if (self.any(half[0]) and !self.any(half[1])) return half[1];
        };
        return null;
    }
};

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

fn testParse(definition: Definition, args: []const []const u8, storage: []u8) Definition.Error!Parsed {
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    return definition.parse(args, fixed.allocator());
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

test "every grammar's conflict and spelling data names its own options" {
    const live = [_]Definition{ fresh_session, live_configure, live_setup };
    inline for (comptime std.meta.tags(Command)) |command| try expectCoherent(command.definition());
    for (live) |definition| try expectCoherent(definition);
}

fn expectCoherent(definition: Definition) !void {
    try std.testing.expect(definition.options.len <= 64);
    for (definition.conflicts) |pair| for (pair) |name| try std.testing.expect(definition.indexOf(name) != null);
    for (definition.positional_conflicts) |name| try std.testing.expect(definition.positional != null and definition.indexOf(name) != null);
    for (definition.options) |option| if (option.hex_of) |named| {
        try std.testing.expect(definition.indexOf(named) != null and option.hex_limit != 0);
    };
}

test "a hex spelling fills its named option and conflicts with it" {
    var storage: [1024]u8 = undefined;
    const plain = try testParse(Command.session_inspect.definition(), &.{ "--session", "a/b" }, &storage);
    const spelled = try testParse(Command.session_inspect.definition(), &.{ "--session-hex", "612f62" }, &storage);
    try std.testing.expectEqualStrings(plain.get("session").?, spelled.get("session").?);
    try std.testing.expect(spelled.has("session-hex") and !spelled.has("session"));
    try expectValidation(.session_inspect, &.{ "--session", "a", "--session-hex", "61" }, error.ConflictingArguments);
    try expectValidation(.session_inspect, &.{ "--session-hex", "61", "--session", "a" }, error.ConflictingArguments);
    // Odd, non-hex, over-bound and non-UTF-8 spellings all fail; help wins.
    const session_over: [2 * 129]u8 = @splat('6');
    const store_over: [2 * 493]u8 = @splat('6');
    inline for (.{ "6", "zz", "ff", &session_over }) |bad| try expectValidation(.session_inspect, &.{ "--session-hex", bad }, error.InvalidHexIdentity);
    try expectValidation(.session_inspect, &.{ "--store-hex", &store_over, "--session", "a" }, error.InvalidHexIdentity);
    try expectValidation(.session_inspect, &.{ "--store-hex", store_over[2..], "--session", "a" }, false);
    try expectValidation(.session_inspect, &.{ "--session-hex", "zz", "--help" }, true);
}

test "hidden test options belong to their operation and stay out of help" {
    var storage: [1024]u8 = undefined;
    const serve = try testParse(Command.host_serve.definition(), &.{ "--fault", "before-commit", "--test-phase-trace", "--fault", "content-read", "--test-retry-waits-ms", "1,1,1" }, &storage);
    try std.testing.expectEqual(@as(usize, 2), serve.all("fault").len);
    try std.testing.expectEqualStrings("content-read", serve.all("fault")[1]);
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
    for (live_setup.options) |option| try std.testing.expect(Command.defaults_configure.definition().optionNamed(option.name) != null);
    var storage: [256]u8 = undefined;
    try std.testing.expectError(error.UnknownArgument, testParse(live_configure, &.{ "--session", "other" }, &storage));
    try std.testing.expectError(error.ConflictingArguments, testParse(live_configure, &.{ "--text-output", "--output-schema", "f" }, &storage));
    try std.testing.expectError(error.ConflictingArguments, testParse(live_setup, &.{ "--clear-model", "--model", "m" }, &storage));
    const fresh = try testParse(fresh_session, &.{ "--model", "m", "--", "--store" }, &storage);
    try std.testing.expectEqualStrings("--store", fresh.positional.?);
    try std.testing.expect(fresh.get("store") == null);
    try std.testing.expectError(error.DuplicateArgument, testParse(fresh_session, &.{ "--model", "m", "--model", "n" }, &storage));
}

test "complete syntax still names the first missing requirement" {
    try std.testing.expectEqualStrings("session", (try expectMissing(.session_send, &.{"hi"})).?);
    try std.testing.expectEqualStrings("text", (try expectMissing(.session_send, &.{ "--session", "a" })).?);
    try std.testing.expect(try expectMissing(.session_send, &.{ "--session", "a", "--", "--text" }) == null);
    // Option values are data: --session's value does not supply the text.
    try std.testing.expectEqualStrings("text", (try expectMissing(.session_send, &.{ "--session", "hi" })).?);
    try std.testing.expectEqualStrings("record", (try expectMissing(.session_send, &.{ "--session", "a", "--key", "k", "hi" })).?);
    try std.testing.expectEqualStrings("key", (try expectMissing(.session_send, &.{ "--session", "a", "--record", "r", "hi" })).?);
    try std.testing.expect(try expectMissing(.session_send, &.{ "--session", "a", "--test-drop-reply", "x" }) != null);
    try std.testing.expect(try expectMissing(.session_resume, &.{ "--store", "/s", "--last" }) == null);
    try std.testing.expect(try expectMissing(.session_resume, &.{ "--store", "/s" }) != null);
    try std.testing.expect(try expectMissing(.request_recover, &.{"HANDLE"}) == null);
    try std.testing.expectEqualStrings("kind", (try expectMissing(.request_recover, &.{ "--record", "r" })).?);
    try std.testing.expect(try expectMissing(.defaults_configure, &.{}) != null);
    try std.testing.expect(try expectMissing(.session_configure, &.{}) == null);
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
