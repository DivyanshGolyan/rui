//! Option grammar shared by CLI and Host.
const std = @import("std");
const caller_error = @import("caller_error.zig");
const session_id = @import("session_id.zig");
pub const Resource = enum { session, request, action, host, defaults, auth, store };

/// Detection-owned argv witness. Text and policy belong to caller_error.
pub const Refusal = struct {
    code: caller_error.Code,
    token: []const u8,
    value: ?[]const u8 = null,
    other: ?[]const u8 = null,
    option: bool = true,
    accepted: ?caller_error.Accepted = null,

    pub fn held(self: Refusal, resource: ?[]const u8, operation: ?[]const u8) caller_error.Held {
        return .{ .resource = resource, .operation = operation, .spelling = self.token, .value = self.value, .other = self.other, .option = self.option, .accepted = self.accepted };
    }
};

pub const Conflict = struct { code: caller_error.Code, a: []const u8, b: []const u8 };
pub const PositionalConflict = struct { code: caller_error.Code, option: []const u8 };

pub const Number = struct {
    min: u64,
    max: u64,
    grammar: []const u8,
    code: caller_error.Code,
};

pub const Option = struct {
    name: []const u8,
    choices: ?[]const []const u8 = null,
    number: ?Number = null,
    argument: ?[]const u8 = null,
    /// A hex spelling of this exact-identity option's bytes, which argv cannot
    /// carry. Both spellings fill the named option; giving both conflicts.
    hex_of: ?[]const u8 = null,
    /// The identity's byte bound; `cli.zig` pins each to its protocol bound.
    hex_limit: usize = 0,
    hex_grammar: ?[]const u8 = null,
    /// Test-only: accepted by its owning operation but absent from help.
    hidden: bool = false,
    /// Accepted more than once; Parsed.all yields every value in order.
    repeated: bool = false,
};
pub fn value(comptime name: []const u8, argument: []const u8) Option {
    if (comptime std.mem.eql(u8, name, "action") or std.mem.eql(u8, name, "turn") or std.mem.eql(u8, name, "operation") or std.mem.eql(u8, name, "position"))
        return numeric(name, argument, 1, std.math.maxInt(i64), .id_malformed);
    if (comptime std.mem.eql(u8, name, "attempt")) return numeric(name, argument, 1, std.math.maxInt(i64), .count_malformed);
    if (comptime std.mem.eql(u8, name, "ordinal")) return numeric(name, argument, 0, std.math.maxInt(i64), .count_malformed);
    if (comptime std.mem.eql(u8, name, "active-capacity")) return numeric(name, argument, 0, std.math.maxInt(usize), .count_malformed);
    if (comptime std.mem.eql(u8, name, "bash-timeout-ms")) return numeric(name, argument, 1, std.math.maxInt(i64), .count_malformed);
    return .{ .name = name, .argument = argument };
}
pub fn numeric(name: []const u8, argument: []const u8, comptime min: u64, comptime max: u64, code: caller_error.Code) Option {
    return .{ .name = name, .argument = argument, .number = .{ .min = min, .max = max, .grammar = std.fmt.comptimePrint("a decimal from {d} to {d}", .{ min, max }), .code = code } };
}
pub fn choice(name: []const u8, comptime E: type) Option {
    const accepted = comptime caller_error.names(E);
    const placeholder = comptime blk: {
        var text: []const u8 = "";
        for (accepted, 0..) |tag, i| text = text ++ (if (i == 0) "" else "|") ++ tag;
        break :blk text;
    };
    return .{ .name = name, .argument = placeholder, .choices = accepted };
}
pub fn repeatedChoice(name: []const u8, comptime E: type) Option {
    var option = choice(name, E);
    option.repeated = true;
    return option;
}
pub fn flag(name: []const u8) Option {
    return .{ .name = name };
}
pub fn hex(name: []const u8, of: []const u8, comptime limit: usize) Option {
    return .{ .name = name, .argument = "HEX", .hex_of = of, .hex_limit = limit, .hex_grammar = std.fmt.comptimePrint("nonempty even-length hex of at most {d} UTF-8 bytes", .{limit}) };
}
pub fn hiddenValue(name: []const u8) Option {
    return .{ .name = name, .argument = "VALUE", .hidden = true };
}
pub fn hiddenNumber(name: []const u8, comptime min: u64, comptime max: u64) Option {
    var option = numeric(name, "N", min, max, .count_malformed);
    option.hidden = true;
    return option;
}
pub fn hiddenFlag(name: []const u8) Option {
    return .{ .name = name, .hidden = true };
}
fn checkOptionName(comptime name: []const u8) void {
    if (name.len != 0 and !@import("cli_option_names.zig").contains(name)) @compileError("no CLI option is named --" ++ name);
}

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
    conflicts: []const Conflict = &.{},
    /// Options an invocation may not combine with the positional.
    positional_conflicts: []const PositionalConflict = &.{},

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
        try writer.writeAll("--help or -h prints this help without accessing runtime state. Mutation receipts and metadata are JSON; explicit content reads stream bytes.\n");
        if (self.resource == .request) try writer.writeAll("request inspect reads once; request wait polls the same request until ended or needing permission.\n");
        if (self.mutation and self.optionNamed("kind") == null) try writer.writeAll("Keep the pre-send recovery identity printed on stderr. Recover with rui request recover HANDLE, or --store PATH --record FILE --kind KIND. Nonzero exit can follow acceptance: inspect the original with rui request inspect; never infer permission to resubmit with a fresh key.\n");
    }

    /// The argument shape of option `name`: null when there is no such
    /// option, a null shape for a flag.
    pub fn argumentOf(self: Definition, name: []const u8) ??[]const u8 {
        return (self.optionNamed(name) orelse return null).argument;
    }

    pub fn optionNamed(self: Definition, name: []const u8) ?Option {
        return self.options[self.indexOf(name) orelse return null];
    }

    pub fn indexOf(self: Definition, name: []const u8) ?usize {
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
    /// unless help is requested. Typed values use the same table as help.
    /// The most tokens an invocation can spell: every option once, with its
    /// value when it takes one.
    pub fn tokenCapacity(comptime self: Definition) usize {
        var count: usize = 0;
        for (self.options) |option| count += if (option.argument == null) 1 else 2;
        return count;
    }

    pub fn parse(self: Definition, args: []const []const u8, allocator: std.mem.Allocator, problem: *Refusal) Error!Parsed {
        const parsed = try self.parseSyntax(args, allocator, problem);
        try parsed.validateValues(problem);
        return parsed;
    }

    fn selectorPresent(self: Definition, args: []const []const u8, selector: []const u8) bool {
        var index: usize = 0;
        while (index < args.len) : (index += 1) {
            const arg = args[index];
            if (std.mem.eql(u8, arg, "--")) return false;
            if (!std.mem.startsWith(u8, arg, "--")) continue;
            const option = self.optionNamed(arg[2..]) orelse continue;
            if (std.mem.eql(u8, option.name, selector)) return true;
            if (option.argument != null) index += 1;
        }
        return false;
    }

    /// The shell checks capture existence before applying fresh-invocation
    /// value rules. Existing captures retain their original admission answer.
    pub fn parseSyntax(self: Definition, args: []const []const u8, allocator: std.mem.Allocator, problem: *Refusal) Error!Parsed {
        problem.* = .{ .code = .memory_exhausted, .token = "argv", .option = false };
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
                if (self.positional == null or parsed.positional != null or (!literal and arg.len > 1 and arg[0] == '-')) {
                    var code: caller_error.Code = if (self.resource == .session and (std.mem.eql(u8, self.name, "start") or std.mem.eql(u8, self.name, "send"))) .message_not_stdin else .positional_unexpected;
                    if (self.positional == null and session_id.valid(arg)) {
                        if (self.indexOf("to") != null and !self.selectorPresent(args, "to")) {
                            code = .session_id_needs_to;
                        } else if (self.indexOf("session") != null and !self.selectorPresent(args, "session")) {
                            code = .session_id_needs_session;
                        }
                    }
                    problem.* = .{ .code = code, .token = arg, .option = false };
                    return error.InvalidArguments;
                }
                parsed.positional = arg;
                parsed.literal_positional = literal;
                continue;
            }
            const n = self.indexOf(arg[2..]) orelse {
                problem.* = .{ .code = .option_unknown, .token = arg, .option = false };
                return error.UnknownArgument;
            };
            const option = self.options[n];
            const bit = @as(u64, 1) << @as(u6, @intCast(n));
            if (parsed.seen & bit != 0 and !option.repeated) {
                problem.* = .{ .code = .option_repeated, .token = option.name };
                return error.DuplicateArgument;
            }
            parsed.seen |= bit;
            if (option.argument == null) continue;
            index += 1;
            if (index == args.len) {
                problem.* = .{ .code = .option_value_missing, .token = option.name, .accepted = if (option.choices) |set| .{ .closed = set } else .{ .grammar = option.argument.? } };
                return error.MissingArgumentValue;
            }
            if (option.repeated) {
                if (parsed.repeat_count == parsed.repeats.len) {
                    problem.* = .{ .code = .option_repeat_limit, .token = option.name, .accepted = .{ .grammar = std.fmt.comptimePrint("at most {d} repeated option values", .{@as(Parsed, undefined).repeats.len}) } };
                    return error.DuplicateArgument;
                }
                // Each option's values stay together, in order, so `all`
                // answers a slice.
                var at = parsed.repeat_count;
                while (at > 0 and parsed.repeat_options[at - 1] != n) : (at -= 1) {}
                if (at == 0) at = parsed.repeat_count;
                std.mem.copyBackwards([]const u8, parsed.repeats[at + 1 .. parsed.repeat_count + 1], parsed.repeats[at..parsed.repeat_count]);
                std.mem.copyBackwards(usize, parsed.repeat_options[at + 1 .. parsed.repeat_count + 1], parsed.repeat_options[at..parsed.repeat_count]);
                parsed.repeats[at] = args[index];
                parsed.repeat_options[at] = n;
                parsed.repeat_count += 1;
                continue;
            }
            // Both spellings of one identity fill the same value.
            const slot = if (option.hex_of) |named| self.indexOf(named).? else n;
            if (parsed.values[slot] != null) {
                for (self.options) |other| {
                    if (parsed.hasNamed(other.name) and !std.mem.eql(u8, other.name, option.name) and std.mem.eql(u8, other.hex_of orelse other.name, self.options[slot].name)) {
                        problem.* = .{ .code = .identity_spelling_repeated, .token = other.name, .other = arg };
                        break;
                    }
                }
                return error.ConflictingArguments;
            }
            parsed.values[slot] = args[index];
            if (option.hex_of != null) hexed |= @as(u64, 1) << @as(u6, @intCast(slot));
        }
        for (self.conflicts) |pair| if (parsed.hasNamed(pair.a) and parsed.hasNamed(pair.b)) {
            problem.* = .{ .code = pair.code, .token = pair.a, .other = pair.b };
            return error.ConflictingArguments;
        };
        if (parsed.positional != null) for (self.positional_conflicts) |conflict| if (parsed.hasNamed(conflict.option)) {
            problem.* = .{ .code = conflict.code, .token = conflict.option, .other = self.positional.? };
            return error.ConflictingArguments;
        };
        if (parsed.help) return parsed;
        for (self.options) |option| {
            const named = self.indexOf(option.hex_of orelse continue).?;
            if (hexed & (@as(u64, 1) << @as(u6, @intCast(named))) == 0) continue;
            parsed.values[named] = decodeHex(allocator, parsed.values[named].?, option.hex_limit) catch |err| {
                problem.* = .{ .code = if (err == error.OutOfMemory) .memory_exhausted else .hex_malformed, .token = option.name, .value = parsed.values[named], .accepted = .{ .grammar = option.hex_grammar.? } };
                return err;
            };
        }
        return parsed;
    }

    pub const Error = error{ DuplicateArgument, UnknownArgument, MissingArgumentValue, ConflictingArguments, InvalidArguments, InvalidInstructionsSource, InvalidHexIdentity, InvalidOptionValue, OutOfMemory };
};

fn validateValue(option: Option, text: []const u8, refusal: *Refusal) Definition.Error!void {
    if (option.choices) |set| {
        for (set) |tag| if (std.mem.eql(u8, tag, text)) return;
        refusal.* = .{ .code = .choice_unsupported, .token = option.name, .value = text, .accepted = .{ .closed = set } };
        return error.InvalidOptionValue;
    }
    if (option.number) |number| {
        refusal.* = .{ .code = number.code, .token = option.name, .value = text, .accepted = .{ .grammar = number.grammar } };
        // parseInt accepts signs and underscores; argv's decimal grammar does not.
        if (text.len == 0) return error.InvalidOptionValue;
        for (text) |byte| if (byte < '0' or byte > '9') return error.InvalidOptionValue;
        const n = std.fmt.parseInt(u64, text, 10) catch return error.InvalidOptionValue;
        if (n < number.min or n > number.max) return error.InvalidOptionValue;
    }
}

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
    /// The option index of each of `repeats`.
    repeat_options: [16]usize = undefined,
    repeat_count: usize = 0,
    positional: ?[]const u8 = null,
    /// The positional followed `--`, so a lone dash is literal text.
    literal_positional: bool = false,
    help: bool = false,

    /// The value of `name` in either spelling; null when not given or not
    /// part of this grammar.
    pub fn get(self: *const Parsed, comptime name: []const u8) ?[]const u8 {
        comptime checkOptionName(name);
        return self.getNamed(name);
    }

    /// Runtime lookup for names from a table; prefer `get` for known names.
    pub fn getNamed(self: *const Parsed, name: []const u8) ?[]const u8 {
        return self.values[self.definition.indexOf(name) orelse return null];
    }

    /// Whether the invocation spelled `name` ("" is the positional).
    pub fn has(self: *const Parsed, comptime name: []const u8) bool {
        comptime checkOptionName(name);
        return self.hasNamed(name);
    }

    /// Runtime lookup for names from a table; "" still names the positional.
    pub fn hasNamed(self: *const Parsed, name: []const u8) bool {
        if (name.len == 0) return self.positional != null;
        const n = self.definition.indexOf(name) orelse return false;
        return self.seen & (@as(u64, 1) << @as(u6, @intCast(n))) != 0;
    }

    /// Every value of the repeatable option, in order.
    pub fn all(self: *const Parsed, comptime name: []const u8) []const []const u8 {
        comptime checkOptionName(name);
        return self.allNamed(name);
    }

    /// Runtime lookup for names from a table; prefer `all` for known names.
    pub fn allNamed(self: *const Parsed, name: []const u8) []const []const u8 {
        const n = self.definition.indexOf(name) orelse return &.{};
        if (!self.definition.options[n].repeated) return &.{};
        const first = std.mem.indexOfScalar(usize, self.repeat_options[0..self.repeat_count], n) orelse return &.{};
        var end = first;
        while (end < self.repeat_count and self.repeat_options[end] == n) end += 1;
        return self.repeats[first..end];
    }

    /// Validate only fresh argv. The capture owner remains the replay authority.
    pub fn validateValues(self: *const Parsed, refusal: *Refusal) Definition.Error!void {
        if (self.help) return;
        if (self.get("instructions")) |source| {
            if (!std.mem.eql(u8, source, "-")) {
                refusal.* = .{ .code = .instructions_source, .token = "instructions", .value = source };
                return error.InvalidInstructionsSource;
            }
            if (std.mem.eql(u8, self.get("output-schema") orelse "", "-")) {
                refusal.* = .{ .code = .stdin_sources_conflict, .token = "instructions", .other = "--output-schema" };
                return error.ConflictingArguments;
            }
        }
        for (self.definition.options) |option| {
            if (option.repeated) {
                for (self.allNamed(option.name)) |text| try validateValue(option, text, refusal);
            } else if (self.getNamed(option.name)) |text| try validateValue(option, text, refusal);
        }
    }

    /// A decimal value of `name`, when given.
    pub fn number(self: *const Parsed, comptime T: type, comptime name: []const u8) !?T {
        comptime checkOptionName(name);
        return try std.fmt.parseInt(T, self.get(name) orelse return null, 10);
    }

    fn any(self: *const Parsed, names: []const []const u8) bool {
        for (names) |name| if (self.hasNamed(name)) return true;
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
