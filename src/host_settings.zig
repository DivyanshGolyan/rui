//! The Host settings document. Settings and its kinds are the only field table;
//! readers, help leaves, source-redacting output and schema walk that table.
//! No I/O or startup caller lives here. Settings is caller-owned, never returned.
const std = @import("std");
const protocol = @import("protocol.zig");
const provider_name = @import("provider_name.zig");
const secret_value = @import("secret_value.zig");
const preset_value = @import("preset_value.zig");
const start_report = @import("start_report.zig");
const hex_value = @import("hex_value.zig");
const defaults = @import("product_defaults.zig");
const http = @import("http1/request.zig");
const endpoint_value = @import("endpoint_value.zig");
const mysql_value = @import("mysql_url_value.zig");
const MysqlValue = mysql_value.ValueWith(max_path_bytes);

// Moved, not copied, from the retiring launch frame and its platform shell.
pub const max_document_bytes = 1024 * 1024;
pub const max_base_url_bytes = endpoint_value.max_endpoint_bytes;
pub const max_path_bytes = std.posix.PATH_MAX - 1;
pub const max_ca_file_bytes = max_path_bytes; // Retiring frame/URL compatibility alias.
pub const max_mcp_servers = 8;
pub const max_mcp_name_bytes = 64;
pub const max_secret_env_name_bytes = 128;
pub const socket_name = "rui.sock";
pub const max_launch_socket_path_bytes = 103;
pub const max_runtime_dir_bytes = max_launch_socket_path_bytes - "/".len - socket_name.len;
pub const default_mcp_call_timeout_ms: u32 = 600_000;
pub const default_bash_timeout_ms: u64 = 5 * 60 * 1000;
pub const default_bash_path = "/bin/bash";

pub const Error = error{ SettingsInvalid, OutOfMemory };
pub const Origin = enum { pipe, file };
/// Checks a borrowed spec; diagnostics must contain field names, never values.
/// The shell adapts core_tools.parseAgentSpec; core tests can supply a pure stub.
pub const PresetCheck = *const fn (std.mem.Allocator, std.json.ObjectMap) error{OutOfMemory}!?[]const u8;
const Kind = enum { text, path, url, count, flag, choice, secret, named, providers, presets };

pub fn Text(comptime capacity: usize) type {
    return struct {
        pub const kind: Kind = .text;
        pub const max_bytes = capacity;
        bytes: [capacity]u8 = undefined,
        len: usize = 0,
        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
        pub fn set(self: *@This(), text: []const u8) error{SettingsInvalid}!void {
            if (text.len > capacity or !std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.SettingsInvalid;
            @memcpy(self.bytes[0..text.len], text);
            self.len = text.len;
        }
    };
}

/// POSIX path/name storage: bounded non-NUL bytes, not Unicode text.
pub fn OsBytes(comptime capacity: usize) type {
    return struct {
        pub const max_bytes = capacity;
        bytes: [capacity]u8 = undefined,
        len: usize = 0,
        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
        pub fn set(self: *@This(), bytes: []const u8) error{SettingsInvalid}!void {
            if (bytes.len > capacity or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.SettingsInvalid;
            @memcpy(self.bytes[0..bytes.len], bytes);
            self.len = bytes.len;
        }
    };
}

pub fn PathWith(comptime capacity: usize) type {
    return PathKind(capacity, .absolute);
}
// Adapter paths preserve their existing interpretation: SQLite and TLS use
// the Host cwd; Bash uses the Session workspace. Other sources are absolute.
const PathRule = enum { absolute, adapter, trust, interface };
fn PathKind(comptime capacity: usize, comptime rule: PathRule) type {
    return struct {
        pub const kind: Kind = .path;
        pub const path_rule = rule;
        pub const absolute = rule == .absolute or rule == .interface;
        pub const allow_empty = rule == .trust;
        pub const max_bytes = capacity;
        text: OsBytes(capacity) = .{},
        /// Default routing is relative to the Host directory. For interface.dir
        /// this selects the platform-derived socket, not an explicit runtime dir.
        anchored: bool = false,
        pub fn slice(self: *const @This()) []const u8 {
            return self.text.slice();
        }
    };
}
pub const Path = PathWith(max_path_bytes);
const UrlRule = enum { https_endpoint, loopback_http };
pub fn Url(comptime rule: UrlRule) type {
    return struct {
        pub const kind: Kind = .url;
        pub const url_rule = rule;
        pub const max_bytes = if (rule == .loopback_http) http.max_url_bytes else max_base_url_bytes;
        text: Text(max_bytes) = .{},
        pub fn slice(self: *const @This()) []const u8 {
            return self.text.slice();
        }
    };
}
pub fn Count(comptime T: type, comptime low: T, comptime high: T, comptime initial: T) type {
    if (low > high or initial < low or initial > high) @compileError("invalid Host count bounds or default");
    return struct {
        pub const kind: Kind = .count;
        pub const Number = T;
        pub const min = low;
        pub const max = high;
        value: T = initial,
    };
}
pub const Flag = struct {
    pub const kind: Kind = .flag;
    value: bool = false,
};
pub fn Choice(comptime E: type, comptime initial: E) type {
    return struct {
        pub const kind: Kind = .choice;
        pub const Enum = E;
        value: E = initial,
    };
}

/// A MySQL URL has its own grammar and decoded-field bounds, not API-key
/// bounds. Only this secret allocates. Neither its raw nor parsed bytes ever
/// borrow the temporary parsing arena.
pub const MysqlBytes = struct {
    raw: []u8 = &.{},
    parsed: ?*MysqlValue = null,
    allocator: ?std.mem.Allocator = null,
    pub fn slice(self: *const MysqlBytes) []const u8 {
        return self.raw;
    }
    pub fn wipe(self: *MysqlBytes) void {
        if (self.allocator) |gpa| {
            std.crypto.secureZero(u8, self.raw);
            gpa.free(self.raw);
            if (self.parsed) |parsed| {
                std.crypto.secureZero(u8, std.mem.asBytes(parsed));
                gpa.destroy(parsed);
            }
        }
        resetVacant(MysqlBytes, self, .{});
    }
    pub fn set(self: *MysqlBytes, gpa: std.mem.Allocator, text: []const u8) Error!void {
        if (text.len > max_document_bytes) return error.SettingsInvalid;
        const parsed = try gpa.create(MysqlValue);
        errdefer {
            std.crypto.secureZero(u8, std.mem.asBytes(parsed));
            gpa.destroy(parsed);
        }
        parsed.* = .{};
        parsed.parse(text) catch return error.SettingsInvalid;
        const raw = try gpa.dupe(u8, text);
        self.wipe();
        self.* = .{ .raw = raw, .parsed = parsed, .allocator = gpa };
    }
};
const SecretDefault = enum { required, provider_saved, mysql };
pub fn Secret(comptime initial: SecretDefault) type {
    return struct {
        pub const kind: Kind = .secret;
        pub const default_source = initial;
        pub const Bytes = if (initial == .mysql) MysqlBytes else secret_value.Key;
        source: Source = .default,
        bytes: Bytes = .{},
        pub const Source = union(enum) { default, env: OsBytes(max_secret_env_name_bytes), file: Path, literal };
        pub fn value(self: *const @This()) []const u8 {
            return self.bytes.slice();
        }
    };
}
pub fn Named(comptime capacity: usize, comptime V: type) type {
    return struct {
        pub const kind: Kind = .named;
        pub const Child = V;
        pub const max = capacity;
        names: [capacity]Text(max_mcp_name_bytes) = @splat(.{}),
        values: [capacity]V = @splat(.{}),
        len: usize = 0,
        pub fn slice(self: *const @This()) []const V {
            return self.values[0..self.len];
        }
    };
}

pub const Settings = struct {
    store: Store = .{ .sqlite = .{} },
    providers: Providers = .{},
    network: Network = .{},
    tools: Tools = .{},
    interface: Interface = .{},
    execution: Execution = .{},
    presets: Presets = .{},
    pub const doc = .{
        .store = "Where the Host keeps canonical facts. One Adapter.",
        .providers = "The providers served, exactly the listed set when present.",
        .network = "Host-wide transport trust.",
        .tools = "The tool Adapters offered to Sessions.",
        .interface = "Where clients reach the Host and what ends it.",
        .execution = "How Turns run.",
        .presets = "Named creation specs held only by this Host.",
    };
    pub fn wipe(self: *Settings) void {
        wipeValue(Settings, self);
    }
    pub fn deinit(self: *Settings) void {
        vacate(Settings, self, .{});
    }
};
pub const Store = union(enum) {
    sqlite: struct {
        dir: PathKind(protocol.max_store_bytes, .adapter) = .{ .anchored = true },
        pub const doc = .{ .dir = "The SQLite Store directory. Default: the Host directory." };
    },
    mysql: struct {
        url: Secret(.mysql) = .{},
        pub const doc = .{ .url = "The MySQL login URL source. TCP verifies TLS; ssl-ca names an absolute PEM path." };
    },
    pub const doc = .{ .sqlite = "SQLite Store.", .mysql = "MySQL Store." };
};
fn ProviderTable(comptime P: type) type {
    const names = @typeInfo(P).@"enum".field_names;
    var types: [names.len]type = undefined;
    var attrs: [names.len]@TypeOf(@typeInfo(struct {
        value: u8 = 0,
    }).@"struct".field_attrs[0]) = @splat(.{});
    for (names, 0..) |name, i| {
        const Entry = ProviderEntry(@field(P, name).facts().credential);
        types[i] = ?Entry;
        const value: ?Entry = .{};
        attrs[i].default_value_ptr = @ptrCast(&value);
    }
    return @Struct(.auto, null, names, &types, &attrs);
}
pub const Providers = struct {
    pub const kind: Kind = .providers;
    pub const Table = ProviderTable(provider_name.Provider);
    entries: Table = .{},
};
pub fn ProviderEntry(comptime credential: provider_name.Facts.Credential) type {
    return switch (credential) {
        .api_key => struct {
            endpoint: ?Url(.https_endpoint) = null,
            key: Secret(.provider_saved) = .{},
            unauthenticated: Flag = .{},
            pub const doc = .{ .endpoint = "Endpoint. Default: the provider's own.", .key = "API-key source. Default: the provider's saved key.", .unauthenticated = "Send no credential to a development endpoint." };
        },
        .sign_in => struct {
            endpoint: ?Url(.https_endpoint) = null,
            credential_file: ?Path = null,
            unauthenticated: Flag = .{},
            pub const doc = .{ .endpoint = "Responses endpoint. Default: the provider's own.", .credential_file = "Sign-in file. Default: the Adapter's saved sign-in.", .unauthenticated = "Send no credential to a development endpoint." };
        },
    };
}
pub const Network = struct {
    ca_file: ?PathKind(max_path_bytes, .trust) = null,
    pub const doc = .{ .ca_file = "Trust only this PEM file; absent uses system trust. Applies to every provider." };
};
pub const Tools = struct {
    bash: struct {
        path: PathKind(max_path_bytes, .adapter) = .{ .text = pathDefault(default_bash_path) },
        timeout_ms: Count(u64, 1, std.math.maxInt(i64), default_bash_timeout_ms) = .{},
        pub const doc = .{ .path = "The Bash executable.", .timeout_ms = "The longest one Bash call may run." };
    } = .{},
    mcp: Named(max_mcp_servers, McpServer) = .{},
    pub const doc = .{ .bash = "The built-in Bash tool.", .mcp = "Named MCP servers whose tools Sessions may use." };
};
pub const McpServer = struct {
    url: Url(.loopback_http) = .{},
    bearer_token: Secret(.required) = .{},
    call_timeout_ms: Count(u32, 1, std.math.maxInt(u32), default_mcp_call_timeout_ms) = .{},
    pub const doc = .{ .url = "Plain HTTP to a loopback literal.", .bearer_token = "Bearer-token source.", .call_timeout_ms = "The longest one tool call may run." };
};
pub const Interface = struct {
    dir: PathKind(max_runtime_dir_bytes, .interface) = .{ .anchored = true },
    lifetime: Choice(Lifetime, .detached) = .{},
    pub const Lifetime = enum { detached, stdin };
    pub const doc = .{ .dir = "Private interface directory. Default: the Host directory; MySQL requires an explicit directory.", .lifetime = "detached: until stopped; stdin: also stop when stdin closes." };
};
pub const Execution = struct {
    active_capacity: Count(usize, 0, std.math.maxInt(usize), defaults.active_capacity) = .{},
    paused: Flag = .{},
    pub const doc = .{ .active_capacity = "How many Turns may run at once.", .paused = "Open with Turns held, as after host_pause." };
};
pub const Presets = struct {
    pub const kind: Kind = .presets;
    specs: []const preset_value.Preset = &.{},
    memory: ?std.heap.ArenaAllocator = null,
    pub fn deinit(self: *Presets) void {
        if (self.memory) |*memory| memory.deinit();
        resetVacant(Presets, self, .{});
    }
};
fn pathDefault(comptime text: []const u8) OsBytes(max_path_bytes) {
    var result: OsBytes(max_path_bytes) = .{};
    result.set(text) catch @compileError("invalid default path");
    return result;
}
fn textDefault(comptime capacity: usize, comptime value: []const u8) Text(capacity) {
    var text: Text(capacity) = .{};
    text.set(value) catch @compileError("invalid default text");
    return text;
}

/// Structured JSON Schema facts passed to a visitor. Secret objects are a
/// choice of exactly one source; literals are pipe-only and never written.
pub const Schema = struct {
    type: enum { string, integer, boolean, object, one_of },
    nullable: bool = false,
    path_accepts_empty: bool = false,
    /// Complete byte-string alternatives; hex is a closed {hex: string}
    /// object with an even lowercase spelling and no additional properties.
    one_of: []const enum { string, hex_object } = &.{},
    hex_object: ?struct {
        property: []const u8 = "hex",
        required: bool = true,
        additional_properties: bool = false,
        pattern: []const u8 = "^([0-9a-f]{2})*$",
        max_length: usize,
    } = null,
    source_paths_are_bytes: bool = false,
    source_env_is_bytes: bool = false,
    min: ?u64 = null,
    max: ?u64 = null,
    max_bytes: ?usize = null,
    choices: []const []const u8 = &.{},
    format: ?[]const u8 = null,
    secret_sources: []const []const u8 = &.{},
    exactly_one_source: bool = false,
    literal_origin: ?Origin = null,
    source_env_max_bytes: ?usize = null,
    source_file_max_bytes: ?usize = null,
    set_capacity: ?usize = null,
    name_max_bytes: ?usize = null,
};
pub const Leaf = struct {
    pattern: []const u8,
    kind: []const u8,
    secret: bool,
    default: []const u8,
    doc: []const u8,
    json_schema: Schema,
    sample_json: []const u8,
    sample_text: []const u8,
};
pub const leaves: []const Leaf = blk: {
    @setEvalBranchQuota(200_000);
    break :blk collect(Settings, .{}, "", "Host settings.", false);
};
pub fn path(comptime pattern: []const u8) []const u8 {
    const found = comptime blk: {
        for (leaves) |leaf| if (std.mem.eql(u8, pattern, leaf.pattern)) break :blk true;
        break :blk false;
    };
    if (!found) @compileError("not a Host settings leaf: " ++ pattern);
    return pattern;
}
fn camel(comptime name: []const u8) []const u8 {
    var result: []const u8 = "";
    var upper = false;
    for (name) |byte| {
        if (byte == '_') {
            upper = true;
            continue;
        }
        result = result ++ .{if (upper) std.ascii.toUpper(byte) else byte};
        upper = false;
    }
    return result;
}
fn joined(comptime prefix: []const u8, comptime name: []const u8) []const u8 {
    return prefix ++ (if (prefix.len == 0) "" else ".") ++ name;
}
fn isKind(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => @hasDecl(T, "kind"),
        else => false,
    };
}
fn collect(comptime T: type, comptime value: T, comptime prefix: []const u8, comptime doc: []const u8, comptime nullable: bool) []const Leaf {
    if (@typeInfo(T) == .optional) return collect(@typeInfo(T).optional.child, value orelse .{}, prefix, doc, true);
    if (comptime isKind(T)) {
        switch (T.kind) {
            .named => {
                var result: []const Leaf = &.{};
                for (collect(T.Child, .{}, joined(prefix, "*"), doc, false)) |child| {
                    var row = child;
                    row.json_schema.set_capacity = T.max;
                    row.json_schema.name_max_bytes = max_mcp_name_bytes;
                    result = result ++ .{row};
                }
                return result;
            },
            .providers => {
                var result: []const Leaf = &.{};
                const info = @typeInfo(T.Table).@"struct";
                for (info.field_names, info.field_types) |name, Field| result = result ++ collect(Field, @field(value.entries, name), joined(prefix, name), doc, false);
                return result;
            },
            else => return &.{leafFor(T, value, if (T.kind == .presets) joined(prefix, "*") else prefix, doc, nullable)},
        }
    }
    var result: []const Leaf = &.{};
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (!@hasDecl(T, "doc")) @compileError("Host settings group needs doc: " ++ @typeName(T));
            for (info.field_names, info.field_types) |name, Field| {
                if (!@hasField(@TypeOf(T.doc), name)) @compileError("Host settings field needs doc: " ++ name);
                result = result ++ collect(Field, @field(value, name), joined(prefix, camel(name)), @field(T.doc, name), false);
            }
        },
        .@"union" => |info| {
            if (!@hasDecl(T, "doc")) @compileError("Host settings union needs doc");
            for (info.field_names, info.field_types) |name, Field| {
                if (!@hasField(@TypeOf(T.doc), name)) @compileError("Host settings Adapter needs doc: " ++ name);
                result = result ++ collect(Field, .{}, joined(prefix, camel(name)), @field(T.doc, name), false);
            }
        },
        else => @compileError("not a Host settings kind: " ++ @typeName(T)),
    }
    return result;
}
fn leafFor(comptime T: type, comptime value: T, comptime pattern: []const u8, comptime doc: []const u8, comptime nullable: bool) Leaf {
    var row: Leaf = .{ .pattern = pattern, .kind = @tagName(T.kind), .secret = T.kind == .secret, .default = "", .doc = doc, .json_schema = .{ .type = .string, .nullable = nullable }, .sample_json = "", .sample_text = "" };
    switch (T.kind) {
        .text => {
            row.default = value.slice();
            row.json_schema.max_bytes = T.max_bytes;
            row.sample_text = if (T.max_bytes == 0) "" else "x";
            row.sample_json = "\"" ++ row.sample_text ++ "\"";
        },
        .path => {
            row.default = if (value.anchored) "(Host directory)" else value.slice();
            row.json_schema.max_bytes = T.max_bytes;
            row.json_schema.format = if (T.absolute) "absolute-path" else null;
            row.json_schema.path_accepts_empty = T.allow_empty;
            row.json_schema.type = .one_of;
            row.json_schema.one_of = &.{ .string, .hex_object };
            row.json_schema.hex_object = .{ .max_length = 2 * T.max_bytes };
            row.json_schema.nullable = true;
            row.sample_json = "\"/tmp/host-settings\"";
            row.sample_text = "/tmp/host-settings";
        },
        .url => {
            row.default = value.slice();
            row.json_schema.max_bytes = T.max_bytes;
            row.json_schema.format = @tagName(T.url_rule);
            row.json_schema.nullable = nullable or value.text.len == 0;
            row.sample_json = if (T.url_rule == .loopback_http) "\"http://127.0.0.1:3000/mcp\"" else "\"https://example.test/v1/responses\"";
            row.sample_text = if (T.url_rule == .loopback_http) "http://127.0.0.1:3000/mcp" else "https://example.test/v1/responses";
        },
        .count => {
            row.default = std.fmt.comptimePrint("{d}", .{value.value});
            row.json_schema.type = .integer;
            row.json_schema.min = T.min;
            row.json_schema.max = T.max;
            row.sample_json = std.fmt.comptimePrint("{d}", .{T.min});
            row.sample_text = row.sample_json;
        },
        .flag => {
            row.default = if (value.value) "true" else "false";
            row.json_schema.type = .boolean;
            row.sample_json = "true";
            row.sample_text = "true";
        },
        .choice => {
            row.default = @tagName(value.value);
            row.json_schema.choices = @typeInfo(T.Enum).@"enum".field_names;
            const names = @typeInfo(T.Enum).@"enum".field_names;
            row.sample_text = names[names.len - 1];
            row.sample_json = "\"" ++ row.sample_text ++ "\"";
        },
        .secret => {
            row.default = "null";
            row.json_schema.type = .object;
            row.json_schema.nullable = true;
            row.json_schema.secret_sources = &.{ "env", "file", "value", "owner" };
            row.json_schema.exactly_one_source = true;
            row.json_schema.literal_origin = .pipe;
            row.json_schema.source_env_max_bytes = max_secret_env_name_bytes;
            row.json_schema.source_paths_are_bytes = true;
            row.json_schema.source_env_is_bytes = true;
            row.json_schema.source_file_max_bytes = Path.max_bytes;
            row.json_schema.max_bytes = if (T.default_source == .mysql) max_document_bytes else secret_value.max_key_bytes;
            row.json_schema.format = if (T.default_source == .mysql) "mysql-login-source" else "credential-source";
            row.sample_json = "{\"env\":\"HOST_SETTINGS_SAMPLE\"}";
            row.sample_text = "env:HOST_SETTINGS_SAMPLE";
        },
        .presets => {
            row.kind = "preset";
            row.default = "null";
            row.json_schema.type = .object;
            row.json_schema.format = "agent-spec";
            row.json_schema.set_capacity = preset_value.max_presets;
            row.json_schema.name_max_bytes = preset_value.max_preset_name_bytes;
            row.sample_json = "{\"workspace\":\"/tmp/host-settings\",\"provider\":\"" ++ @tagName(std.enums.values(provider_name.Provider)[0]) ++ "\",\"model\":\"sample-model\",\"effort\":null,\"compactAt\":1000,\"tools\":[\"bash\"],\"permissionMode\":\"ask\"}";
            row.sample_text = row.sample_json;
        },
        .named, .providers => @compileError("set is not an atomic leaf"),
    }
    if (nullable) row.default = "null";
    return row;
}
/// Container facts make the leaf schemas a complete document grammar:
/// closed objects, exactly-one Adapter unions, and replacing named sets.
pub const Group = struct {
    pattern: []const u8,
    kind: enum { object, one_adapter, providers, named },
    doc: []const u8,
    nullable: bool = false,
    keys: []const []const u8 = &.{},
    max_entries: ?usize = null,
    min_entries: usize = 0,
    name_max_bytes: ?usize = null,
    name_format: ?enum { mcp, preset } = null,
};
pub const groups: []const Group = blk: {
    @setEvalBranchQuota(200_000);
    break :blk collectGroups(Settings, "", "Host settings.", false);
};
fn fieldKeys(comptime T: type) []const []const u8 {
    const info = @typeInfo(T);
    const names = switch (info) {
        .@"struct" => info.@"struct".field_names,
        .@"union" => info.@"union".field_names,
        else => unreachable,
    };
    var keys: []const []const u8 = &.{};
    for (names) |name| keys = keys ++ .{camel(name)};
    return keys;
}
fn collectGroups(comptime T: type, comptime prefix: []const u8, comptime doc: []const u8, comptime nullable: bool) []const Group {
    if (@typeInfo(T) == .optional) return collectGroups(@typeInfo(T).optional.child, prefix, doc, true);
    if (comptime isKind(T)) return switch (T.kind) {
        .named => &[_]Group{.{ .pattern = prefix, .kind = .named, .doc = doc, .max_entries = T.max, .name_max_bytes = max_mcp_name_bytes, .name_format = .mcp }} ++ collectGroups(T.Child, joined(prefix, "*"), doc, false),
        .presets => &.{.{ .pattern = prefix, .kind = .named, .doc = doc, .max_entries = preset_value.max_presets, .name_max_bytes = preset_value.max_preset_name_bytes, .name_format = .preset }},
        .providers => blk: {
            const info = @typeInfo(T.Table).@"struct";
            var result: []const Group = &.{.{ .pattern = prefix, .kind = .providers, .doc = doc, .keys = info.field_names, .max_entries = info.field_names.len }};
            for (info.field_names, info.field_types) |name, Field| result = result ++ collectGroups(Field, joined(prefix, name), doc, false);
            break :blk result;
        },
        else => &.{},
    };
    var result: []const Group = &.{.{ .pattern = prefix, .kind = if (@typeInfo(T) == .@"union") .one_adapter else .object, .doc = doc, .nullable = nullable, .keys = fieldKeys(T), .min_entries = if (@typeInfo(T) == .@"union") 1 else 0, .max_entries = if (@typeInfo(T) == .@"union") 1 else null }};
    switch (@typeInfo(T)) {
        .@"struct" => |info| for (info.field_names, info.field_types) |name, Field| {
            result = result ++ collectGroups(Field, joined(prefix, camel(name)), @field(T.doc, name), false);
        },
        .@"union" => |info| for (info.field_names, info.field_types) |name, Field| {
            result = result ++ collectGroups(Field, joined(prefix, camel(name)), @field(T.doc, name), false);
        },
        else => @compileError("not a Host settings kind"),
    }
    return result;
}
/// A visitor may consume container facts with pub group(Group), then receives
/// every leaf with leaf(Leaf). No schema or document is buffered at runtime.
pub fn schema(visitor: anytype) !void {
    const V = switch (@typeInfo(@TypeOf(visitor))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(visitor),
    };
    if (@hasDecl(V, "group")) for (groups) |group| try visitor.group(group);
    for (leaves) |leaf| try visitor.leaf(leaf);
}

// ---- Strict JSON boundary ----------------------------------------------------
fn refuse(failure: *start_report.Failure, leaf_path: []const u8, reason: []const u8) error{SettingsInvalid} {
    failure.code = .settings_invalid;
    var out = std.Io.Writer.fixed(&failure.message.bytes);
    // Diagnostic truncation, never semantic input truncation. Stay on UTF-8.
    var end: usize = @min(leaf_path.len, failure.message.bytes.len / 2);
    while (!std.unicode.utf8ValidateSlice(leaf_path[0..end]) and end > 0) end -= 1;
    out.writeAll(if (leaf_path.len == 0) "$" else leaf_path[0..end]) catch unreachable;
    out.writeAll(": ") catch unreachable;
    // A diagnostic may be clipped; no semantic input is ever clipped.
    out.writeAll(if (std.unicode.utf8ValidateSlice(reason)) reason else "invalid value") catch {};
    end = out.buffered().len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(out.buffered()[0..end])) end -= 1;
    failure.message.len = end;
    return error.SettingsInvalid;
}
/// Paths are diagnostics, not semantic keys. Cap the copy before allocating:
/// a very long unknown key must not multiply into every descendant's path.
/// Callers supply only their wiping arena; semantic map keys remain intact.
fn childPath(arena: std.mem.Allocator, prefix: []const u8, name: []const u8) error{OutOfMemory}![]const u8 {
    const separator: usize = @intFromBool(prefix.len != 0);
    const capacity = start_report.max_refusal_message_bytes / 2;
    const result = try arena.alloc(u8, @min(capacity, prefix.len + separator + name.len));
    const prefix_len = @min(prefix.len, result.len);
    @memcpy(result[0..prefix_len], prefix[0..prefix_len]);
    var end = prefix_len;
    if (separator != 0 and end < result.len) {
        result[end] = '.';
        end += 1;
    }
    const name_len = @min(name.len, result.len - end);
    @memcpy(result[end..][0..name_len], name[0..name_len]);
    end += name_len;
    while (end > 0 and !std.unicode.utf8ValidateSlice(result[0..end])) end -= 1;
    return result[0..end];
}

const Read = struct { arena: std.mem.Allocator, gpa: std.mem.Allocator, origin: Origin, check: PresetCheck, failure: *start_report.Failure };
const Json = struct {
    scanner: std.json.Scanner,
    read: *const Read,
    fn next(self: *Json, at: []const u8) Error!std.json.Token {
        return self.scanner.nextAllocMax(self.read.arena, .alloc_always, max_document_bytes) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => refuse(self.read.failure, at, "must be well-formed JSON"),
        };
    }
};
fn tokenText(token: std.json.Token) []const u8 {
    return switch (token) {
        .string, .number => |text| text,
        .allocated_string, .allocated_number => |text| text,
        else => unreachable,
    };
}
const JsonFrame = struct {
    value: std.json.Value,
    path: []const u8,
    key: ?[]const u8 = null,
    key_path: []const u8 = "",
};
fn parseJson(read: *const Read, document: []const u8, at: []const u8) Error!std.json.Value {
    if (document.len > max_document_bytes) return refuse(read.failure, at, "exceeds the document byte bound");
    var json: Json = .{ .scanner = .initCompleteInput(read.arena, document), .read = read };
    defer json.scanner.deinit();
    // An explicit, arena-owned stack bounds nesting without spending a native
    // stack frame per untrusted object or array. Keys remain decoded, so escaped
    // duplicates have exactly the same identity as their unescaped spelling.
    const frames = try read.arena.alloc(JsonFrame, protocol.max_json_depth);
    var depth: usize = 0;
    var root: ?std.json.Value = null;
    while (true) {
        const here = if (depth == 0) at else if (frames[depth - 1].key != null) frames[depth - 1].key_path else frames[depth - 1].path;
        const token = try json.next(here);
        if (token == .end_of_document) {
            if (depth != 0 or root == null) return refuse(read.failure, here, "must contain one JSON value");
            return root.?;
        }
        if (depth > 0) {
            const parent = &frames[depth - 1];
            if (parent.value == .object and parent.key == null and (token == .string or token == .allocated_string)) {
                const key = tokenText(token);
                const key_path = try childPath(read.arena, parent.path, key);
                if (parent.value.object.contains(key)) return refuse(read.failure, key_path, "duplicate key");
                parent.key = key;
                parent.key_path = key_path;
                continue;
            }
        }
        const value: std.json.Value = switch (token) {
            .object_begin, .array_begin => {
                if (depth == frames.len) return refuse(read.failure, here, "exceeds the JSON nesting bound");
                frames[depth] = .{ .value = if (token == .object_begin) .{ .object = .{} } else .{ .array = .init(read.arena) }, .path = here };
                depth += 1;
                continue;
            },
            .object_end, .array_end => blk: {
                if (depth == 0) return refuse(read.failure, here, "unexpected end of JSON container");
                depth -= 1;
                break :blk frames[depth].value;
            },
            .null => .null,
            .true => .{ .bool = true },
            .false => .{ .bool = false },
            .string, .allocated_string => .{ .string = tokenText(token) },
            .number, .allocated_number => .{ .number_string = tokenText(token) },
            else => return refuse(read.failure, here, "must be a JSON value"),
        };
        if (depth == 0) {
            if (root != null) return refuse(read.failure, here, "must contain exactly one JSON value");
            root = value;
        } else {
            const parent = &frames[depth - 1];
            switch (parent.value) {
                .object => |*fields| {
                    try fields.put(read.arena, parent.key orelse return refuse(read.failure, here, "object key is missing"), value);
                    parent.key = null;
                },
                .array => |*array| try array.append(value),
                else => unreachable,
            }
        }
    }
}

/// Applies one strict JSON object. A supplied set replaces that set; omitted
/// fields leave defaults or earlier assignments intact. On refusal the caller
/// must not seal the partially assigned settings; all secret bytes are wiped.
pub fn apply(settings: *Settings, gpa: std.mem.Allocator, document: []const u8, origin: Origin, check: PresetCheck, failure: *start_report.Failure) Error!void {
    var wiping: secret_value.WipingAllocator = .{ .backing = gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const read: Read = .{ .arena = memory.allocator(), .gpa = gpa, .origin = origin, .check = check, .failure = failure };
    errdefer settings.wipe();
    const value = try parseJson(&read, document, "");
    try readValue(Settings, settings, value, "", &read);
}
fn string(value: std.json.Value, at: []const u8, read: *const Read) Error![]const u8 {
    return if (value == .string) value.string else refuse(read.failure, at, "must be text");
}
fn object(value: std.json.Value, at: []const u8, read: *const Read) Error!std.json.ObjectMap {
    return if (value == .object) value.object else refuse(read.failure, at, "must be an object");
}
fn readValue(comptime T: type, dest: *T, value: std.json.Value, at: []const u8, read: *const Read) Error!void {
    if (@typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (value == .null) {
            vacate(T, dest, null);
            return;
        }
        if (dest.* == null) resetVacant(T, dest, .{});
        return readValue(Child, &dest.*.?, value, at, read);
    }
    if (comptime isKind(T)) return readKind(T, dest, value, at, read);
    const fields = try object(value, at, read);
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            var entries = fields.iterator();
            while (entries.next()) |entry| {
                inline for (info.field_names, info.field_types) |name, Field| {
                    if (std.mem.eql(u8, entry.key_ptr.*, comptime camel(name))) {
                        try readValue(Field, &@field(dest, name), entry.value_ptr.*, try childPath(read.arena, at, entry.key_ptr.*), read);
                        break;
                    }
                } else return refuse(read.failure, try childPath(read.arena, at, entry.key_ptr.*), "unknown setting");
            }
        },
        .@"union" => |info| {
            if (fields.count() != 1) return refuse(read.failure, at, "must select exactly one Adapter");
            var entries = fields.iterator();
            const entry = entries.next().?;
            inline for (info.field_names, info.field_types) |name, Field| {
                if (std.mem.eql(u8, entry.key_ptr.*, comptime camel(name))) {
                    if (std.meta.activeTag(dest.*) != @field(std.meta.Tag(T), name)) {
                        vacate(T, dest, @unionInit(T, name, .{}));
                    }
                    try readValue(Field, &@field(dest, name), entry.value_ptr.*, try childPath(read.arena, at, entry.key_ptr.*), read);
                    break;
                }
            } else return refuse(read.failure, try childPath(read.arena, at, entry.key_ptr.*), "unknown Adapter");
        },
        else => @compileError("not a Host settings kind: " ++ @typeName(T)),
    }
}
fn readKind(comptime T: type, dest: *T, value: std.json.Value, at: []const u8, read: *const Read) Error!void {
    switch (T.kind) {
        .text => dest.set(try string(value, at, read)) catch return refuse(read.failure, at, "must be bounded UTF-8 without NUL"),
        .path => {
            if (value == .null) {
                dest.text.len = 0;
                dest.anchored = true;
                return;
            }
            const raw = try readOsBytes(T.max_bytes, value, at, read);
            const text = if (T.path_rule == .interface) std.mem.trimEnd(u8, raw, "/") else raw;
            if ((text.len == 0 and !T.allow_empty) or (T.absolute and !std.fs.path.isAbsolute(text))) return refuse(read.failure, at, "must be an absolute path");
            dest.text.set(text) catch return refuse(read.failure, at, "path exceeds its byte bound or contains NUL");
            dest.anchored = false;
        },
        .url => {
            if (value == .null) {
                dest.text.len = 0;
                return;
            }
            const text = try string(value, at, read);
            switch (T.url_rule) {
                .https_endpoint => endpoint_value.validateEndpoint(text) catch return refuse(read.failure, at, "must be a valid HTTPS or loopback HTTP endpoint"),
                .loopback_http => _ = http.parseTarget(text) catch return refuse(read.failure, at, "must be plain HTTP to a loopback literal"),
            }
            dest.text.set(text) catch return refuse(read.failure, at, "URL exceeds its byte bound");
        },
        .count => {
            if (value != .number_string) return refuse(read.failure, at, "must be an integer");
            const number = std.fmt.parseInt(T.Number, value.number_string, 10) catch return refuse(read.failure, at, "must be a bounded integer");
            if (number < T.min or number > T.max) return refuse(read.failure, at, "integer is outside its bounds");
            dest.value = number;
        },
        .flag => {
            if (value != .bool) return refuse(read.failure, at, "must be a boolean");
            dest.value = value.bool;
        },
        .choice => {
            dest.value = std.meta.stringToEnum(T.Enum, try string(value, at, read)) orelse return refuse(read.failure, at, "must be a listed choice");
        },
        .secret => {
            if (value == .null) {
                vacate(T, dest, .{});
                return;
            }
            const source = try object(value, at, read);
            if (source.count() != 1) return refuse(read.failure, at, "must name exactly one secret source");
            var sources = source.iterator();
            const entry = sources.next().?;
            const name = entry.key_ptr.*;
            const input = entry.value_ptr.*;
            if (std.mem.eql(u8, name, "env")) {
                const text = try readOsBytes(max_secret_env_name_bytes, input, at, read);
                if (!validEnv(text)) return refuse(read.failure, at, "must name an environment variable");
                vacate(T, dest, .{});
                dest.source = .{ .env = .{} };
                dest.source.env.set(text) catch return refuse(read.failure, at, "environment variable name exceeds its byte bound");
            } else if (std.mem.eql(u8, name, "file")) {
                vacate(T, dest, .{});
                dest.source = .{ .file = .{} };
                if (input == .null) return refuse(read.failure, at, "secret file must name an absolute path");
                try readKind(Path, &dest.source.file, input, at, read);
            } else if (std.mem.eql(u8, name, "value")) {
                if (read.origin != .pipe) return refuse(read.failure, at, "a file must name a secret source, not a literal");
                const text = try string(input, at, read);
                if (T.default_source == .mysql) {
                    dest.bytes.set(read.gpa, text) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return refuse(read.failure, at, "must be a valid MySQL login URL"),
                    };
                } else {
                    if (!secret_value.valid(text)) return refuse(read.failure, at, "must be a bounded visible-ASCII credential");
                    vacate(T, dest, .{});
                    @memcpy(dest.bytes.bytes[0..text.len], text);
                    dest.bytes.len = text.len;
                }
                resetVacant(T.Source, &dest.source, .literal);
            } else if (std.mem.eql(u8, name, "owner")) {
                if (input != .bool or !input.bool) return refuse(read.failure, at, "owner marker must be true");
                vacate(T, dest, .{});
                dest.source = .literal;
            } else return refuse(read.failure, at, "unknown secret source");
        },
        .named => {
            const entries = try object(value, at, read);
            if (entries.count() > T.max) return refuse(read.failure, at, "too many named entries");
            vacate(T, dest, .{});
            var iterator = entries.iterator();
            while (iterator.next()) |entry| {
                const here = try childPath(read.arena, at, entry.key_ptr.*);
                if (!validName(entry.key_ptr.*)) return refuse(read.failure, here, "invalid entry name");
                const i = dest.len;
                vacate(T.Child, &dest.values[i], .{});
                try dest.names[i].set(entry.key_ptr.*);
                dest.len += 1;
                try readValue(T.Child, &dest.values[i], entry.value_ptr.*, here, read);
            }
        },
        .providers => {
            const entries = try object(value, at, read);
            vacate(T, dest, .{});
            const info = @typeInfo(T.Table).@"struct";
            inline for (info.field_names, info.field_types) |name, Field| vacate(Field, &@field(dest.entries, name), null);
            var iterator = entries.iterator();
            while (iterator.next()) |entry| {
                inline for (info.field_names, info.field_types) |name, Field| {
                    if (std.mem.eql(u8, name, entry.key_ptr.*)) {
                        try readValue(Field, &@field(dest.entries, name), entry.value_ptr.*, try childPath(read.arena, at, name), read);
                        break;
                    }
                } else return refuse(read.failure, try childPath(read.arena, at, entry.key_ptr.*), "unknown provider");
            }
        },
        .presets => try readPresets(dest, value, at, read),
    }
}
fn validEnv(text: []const u8) bool {
    return text.len != 0 and std.mem.indexOfAny(u8, text, "=\x00") == null;
}
fn readOsBytes(comptime capacity: usize, value: std.json.Value, at: []const u8, read: *const Read) Error![]const u8 {
    if (value == .string) return value.string;
    const fields = try object(value, at, read);
    if (fields.count() != 1 or !fields.contains("hex")) return refuse(read.failure, at, "must be a string or an object containing only hex");
    const encoded = try string(fields.get("hex").?, at, read);
    if (encoded.len / 2 > capacity) return refuse(read.failure, at, "hex exceeds the byte bound");
    const buffer = try read.arena.alloc(u8, encoded.len / 2);
    return hex_value.decodeInto(buffer, encoded, .lower) catch return refuse(read.failure, at, "hex must have even length and lowercase hex digits");
}

pub fn validName(text: []const u8) bool {
    if (text.len == 0 or text.len > max_mcp_name_bytes) return false;
    for (text) |byte| if (!(std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-')) return false;
    return true;
}
fn readPresets(dest: *Presets, value: std.json.Value, at: []const u8, read: *const Read) Error!void {
    const entries = try object(value, at, read);
    if (entries.count() > preset_value.max_presets) return refuse(read.failure, at, "too many presets");
    var iterator = entries.iterator();
    while (iterator.next()) |entry| {
        const here = try childPath(read.arena, at, entry.key_ptr.*);
        if (!preset_value.validPresetName(entry.key_ptr.*)) return refuse(read.failure, here, "invalid preset name");
        const spec = try object(entry.value_ptr.*, here, read);
        if (try read.check(read.arena, spec)) |reason| return refuse(read.failure, here, reason);
    }
    if (entries.count() == 0) {
        dest.deinit();
        return;
    }
    // Only presets are retained from the parse tree. MySQL separately owns its
    // parsed login and raw credential; it never retains the document arena.
    var memory: std.heap.ArenaAllocator = .init(read.gpa);
    errdefer memory.deinit();
    const encoded = try std.json.Stringify.valueAlloc(read.arena, value, .{});
    const saved = std.json.parseFromSliceLeaky(std.json.Value, memory.allocator(), encoded, .{ .allocate = .alloc_always, .parse_numbers = false }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    const retained = try memory.allocator().alloc(preset_value.Preset, entries.count());
    var items = saved.object.iterator();
    for (retained) |*preset| {
        const entry = items.next().?;
        preset.* = .{ .name = entry.key_ptr.*, .spec = entry.value_ptr.object };
    }
    dest.deinit();
    dest.* = .{ .specs = retained, .memory = memory };
}

// ---- CLI assignment: the same kinds, no second setting table ------------------
pub fn assign(settings: *Settings, gpa: std.mem.Allocator, leaf_path: []const u8, value: []const u8, check: PresetCheck, failure: *start_report.Failure) Error!void {
    var wiping: secret_value.WipingAllocator = .{ .backing = gpa };
    var memory: std.heap.ArenaAllocator = .init(wiping.allocator());
    defer memory.deinit();
    const read: Read = .{ .arena = memory.allocator(), .gpa = gpa, .origin = .file, .check = check, .failure = failure };
    errdefer settings.wipe();
    if (leaf_path.len == 0) return unknown(failure, leaf_path);
    try assignAt(Settings, settings, leaf_path, value, leaf_path, &read);
}
fn cliValue(comptime T: type, input: []const u8, at: []const u8, read: *const Read) Error!std.json.Value {
    const Bare = if (@typeInfo(T) == .optional) @typeInfo(T).optional.child else T;
    if (comptime isKind(Bare) and Bare.kind == .path) return .{ .string = input };
    if (std.mem.eql(u8, input, "null") or std.mem.startsWith(u8, input, "\"") or std.mem.startsWith(u8, input, "{") or std.mem.startsWith(u8, input, "[")) return parseJson(read, input, at);
    if (@typeInfo(T) == .optional) return cliValue(@typeInfo(T).optional.child, input, at, read);
    if (comptime isKind(T)) switch (T.kind) {
        .text, .path, .url, .choice => return .{ .string = input },
        .count, .flag => return parseJson(read, input, at),
        .secret => {
            var source: std.json.ObjectMap = .{};
            if (std.mem.startsWith(u8, input, "env:")) try source.put(read.arena, "env", .{ .string = input["env:".len..] }) else if (std.mem.startsWith(u8, input, "file:")) try source.put(read.arena, "file", .{ .string = input["file:".len..] }) else return refuse(read.failure, at, "CLI secrets must name env:NAME or file:PATH");
            return .{ .object = source };
        },
        else => {},
    };
    return parseJson(read, input, at);
}
fn assignAt(comptime T: type, dest: *T, remaining: []const u8, input: []const u8, full: []const u8, read: *const Read) Error!void {
    if (remaining.len == 0) return readValue(T, dest, try cliValue(T, input, full, read), full, read);
    if (@typeInfo(T) == .optional) {
        if (dest.* == null) resetVacant(T, dest, .{});
        return assignAt(@typeInfo(T).optional.child, &dest.*.?, remaining, input, full, read);
    }
    const dot = std.mem.indexOfScalar(u8, remaining, '.');
    const head = remaining[0 .. dot orelse remaining.len];
    const tail = if (dot) |index| remaining[index + 1 ..] else "";
    if (head.len == 0 or (dot != null and tail.len == 0)) return unknown(read.failure, full);
    if (comptime isKind(T)) {
        switch (T.kind) {
            .providers => {
                const info = @typeInfo(T.Table).@"struct";
                inline for (info.field_names, info.field_types) |name, Field| {
                    if (std.mem.eql(u8, name, head)) return assignAt(Field, &@field(dest.entries, name), tail, input, full, read);
                }
                return unknown(read.failure, full);
            },
            .named => {
                if (!validName(head)) return refuse(read.failure, full, "invalid entry name");
                var index: usize = 0;
                while (index < dest.len and !std.mem.eql(u8, dest.names[index].slice(), head)) : (index += 1) {}
                if (tail.len == 0 and std.mem.eql(u8, input, "null")) {
                    if (index < dest.len) {
                        vacate(T.Child, &dest.values[index], .{});
                        vacate(@TypeOf(dest.names[index]), &dest.names[index], .{});
                        var next = index + 1;
                        while (next < dest.len) : (next += 1) {
                            moveSlot(@TypeOf(dest.names[next]), &dest.names[next - 1], &dest.names[next]);
                            moveSlot(T.Child, &dest.values[next - 1], &dest.values[next]);
                        }
                        dest.len -= 1;
                    }
                    return;
                }
                if (index == dest.len) {
                    if (dest.len == T.max) return refuse(read.failure, full, "too many named entries");
                    vacate(T.Child, &dest.values[index], .{});
                    try dest.names[index].set(head);
                    dest.len += 1;
                }
                return assignAt(T.Child, &dest.values[index], tail, input, full, read);
            },
            .presets => {
                if (tail.len != 0) return unknown(read.failure, full);
                if (!preset_value.validPresetName(head)) return refuse(read.failure, full, "invalid preset name");
                var entries: std.json.ObjectMap = .{};
                for (dest.specs) |preset| if (!std.mem.eql(u8, preset.name, head)) try entries.put(read.arena, preset.name, .{ .object = preset.spec });
                const value = try parseJson(read, input, full);
                if (value != .null) try entries.put(read.arena, head, value);
                return readPresets(dest, .{ .object = entries }, "presets", read);
            },
            else => return unknown(read.failure, full),
        }
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            inline for (info.field_names, info.field_types) |name, Field| {
                if (std.mem.eql(u8, head, comptime camel(name))) return assignAt(Field, &@field(dest, name), tail, input, full, read);
            }
        },
        .@"union" => |info| {
            inline for (info.field_names, info.field_types) |name, Field| {
                if (std.mem.eql(u8, head, comptime camel(name))) {
                    if (std.meta.activeTag(dest.*) != @field(std.meta.Tag(T), name)) {
                        vacate(T, dest, @unionInit(T, name, .{}));
                    }
                    return assignAt(Field, &@field(dest, name), tail, input, full, read);
                }
            }
        },
        else => @compileError("not a Host settings kind"),
    }
    return unknown(read.failure, full);
}
fn unknown(failure: *start_report.Failure, input: []const u8) error{SettingsInvalid} {
    var best = leaves[0].pattern;
    var distance: usize = std.math.maxInt(usize);
    for (leaves) |leaf| {
        const score = editDistance(input, leaf.pattern);
        if (score < distance) {
            distance = score;
            best = leaf.pattern;
        }
    }
    var reason: [start_report.max_refusal_message_bytes / 2]u8 = undefined;
    const message = std.fmt.bufPrint(&reason, "unknown setting; nearest leaf: {s}", .{best}) catch "unknown setting";
    return refuse(failure, input, message);
}
fn editDistance(a: []const u8, b: []const u8) usize {
    // Pattern length, not untrusted input, bounds the work storage.
    const max_pattern = comptime blk: {
        var len: usize = 0;
        for (leaves) |leaf| len = @max(len, leaf.pattern.len);
        break :blk len;
    };
    var row: [max_pattern + 1]usize = undefined;
    for (row[0 .. b.len + 1], 0..) |*cell, i| cell.* = i;
    for (a, 0..) |x, i| {
        var diagonal = row[0];
        row[0] = i + 1;
        for (b, 0..) |y, j| {
            const above = row[j + 1];
            row[j + 1] = @min(@min(row[j] + 1, above + 1), diagonal + @intFromBool(x != y));
            diagonal = above;
        }
    }
    return row[b.len];
}

// ---- Lifetimes, anchoring and the proof --------------------------------------
/// Reset storage only after its resources have been disposed or transferred.
/// Defaults may contain undefined bytes: assigning them alone is not erasure.
/// The replacement is comptime-only, never a by-value resolved credential.
fn resetVacant(comptime T: type, value: *T, comptime replacement: T) void {
    std.crypto.secureZero(u8, std.mem.asBytes(value));
    value.* = replacement;
    // Checked builds may poison undefined default Key storage. A vacant
    // credential buffer still has the existing all-zero wipe guarantee.
    wipeValue(T, value);
}
/// The sole destructive replacement path for an owned settings slot.
fn vacate(comptime T: type, value: *T, comptime replacement: T) void {
    dispose(T, value);
    resetVacant(T, value, replacement);
}
/// Move, never clone, a slot. Source handles belong to the destination after
/// memcpy, so resetting the source must not dispose them a second time.
fn moveSlot(comptime T: type, dest: *T, source: *T) void {
    std.debug.assert(dest != source);
    vacate(T, dest, .{});
    @memcpy(std.mem.asBytes(dest), std.mem.asBytes(source));
    resetVacant(T, source, .{});
}
fn wipeValue(comptime T: type, value: *T) void {
    if (@typeInfo(T) == .optional) {
        if (value.*) |*present| wipeValue(@typeInfo(T).optional.child, present);
        return;
    }
    if (comptime isKind(T)) {
        switch (T.kind) {
            .secret => value.bytes.wipe(),
            .named => for (&value.values) |*entry| wipeValue(T.Child, entry),
            .providers => {
                const info = @typeInfo(T.Table).@"struct";
                inline for (info.field_names, info.field_types) |name, Field| wipeValue(Field, &@field(value.entries, name));
            },
            else => {},
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| wipeValue(Field, &@field(value, name)),
        .@"union" => switch (value.*) {
            inline else => |*payload| wipeValue(@TypeOf(payload.*), payload),
        },
        // Reset helpers also visit raw metadata and empty ownership handles.
        // Only typed Secret values own bytes; pointers are never followed.
        else => {},
    }
}
fn dispose(comptime T: type, value: *T) void {
    if (@typeInfo(T) == .optional) {
        if (value.*) |*present| dispose(@typeInfo(T).optional.child, present);
        return;
    }
    if (comptime isKind(T)) {
        switch (T.kind) {
            .secret => value.bytes.wipe(),
            .presets => value.deinit(),
            .named => for (&value.values) |*entry| dispose(T.Child, entry),
            .providers => {
                const info = @typeInfo(T.Table).@"struct";
                inline for (info.field_names, info.field_types) |name, Field| dispose(Field, &@field(value.entries, name));
            },
            else => {},
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| dispose(Field, &@field(value, name)),
        .@"union" => switch (value.*) {
            inline else => |*payload| dispose(@TypeOf(payload.*), payload),
        },
        else => @compileError("not a Host settings kind"),
    }
}
pub fn anchor(settings: *Settings, host_dir: []const u8) error{SettingsInvalid}!void {
    if (settings.store == .mysql and settings.interface.dir.anchored) return error.SettingsInvalid;
    if (host_dir.len == 0 or !std.fs.path.isAbsolute(host_dir)) return error.SettingsInvalid;
    const trimmed = std.mem.trimEnd(u8, host_dir, "/");
    try anchorValue(Settings, settings, if (trimmed.len == 0) "/" else trimmed);
}
fn anchorValue(comptime T: type, value: *T, host_dir: []const u8) error{SettingsInvalid}!void {
    if (@typeInfo(T) == .optional) {
        if (value.*) |*present| try anchorValue(@typeInfo(T).optional.child, present, host_dir);
        return;
    }
    if (comptime isKind(T)) {
        switch (T.kind) {
            .path => if (value.anchored and T.path_rule != .interface) {
                try value.text.set(host_dir);
                value.anchored = false;
            },
            .named => {
                if (value.len > T.max) return error.SettingsInvalid;
                for (value.values[0..value.len]) |*entry| try anchorValue(T.Child, entry, host_dir);
            },
            .providers => {
                const info = @typeInfo(T.Table).@"struct";
                inline for (info.field_names, info.field_types) |name, Field| try anchorValue(Field, &@field(value.entries, name), host_dir);
            },
            else => {},
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| try anchorValue(Field, &@field(value, name), host_dir),
        .@"union" => switch (value.*) {
            inline else => |*payload| try anchorValue(@TypeOf(payload.*), payload, host_dir),
        },
        else => @compileError("not a Host settings kind"),
    }
}
/// Borrows Settings until its next mutation or deinit. There is no ordinary
/// struct-literal route to a proof: its pointer targets an opaque type. As
/// with every Zig handle, an explicit unsafe pointer cast is outside the API.
pub const Prepared = struct {
    proof: *const Proof,
    const Proof = opaque {};
    pub fn get(self: Prepared) *const Settings {
        return @ptrCast(@alignCast(self.proof));
    }
};

pub fn seal(settings: *const Settings, failure: *start_report.Failure) error{SettingsInvalid}!Prepared {
    try validateShape(Settings, settings, "", failure);
    if (!settings.interface.dir.anchored and (settings.interface.dir.slice().len == 0 or std.mem.eql(u8, settings.interface.dir.slice(), "/"))) return refuse(failure, "interface.dir", "must be anchored to a non-root interface directory");
    if (settings.store == .mysql and settings.interface.dir.anchored) return refuse(failure, "interface.dir", "MySQL requires an explicit interface directory");
    if (settings.store == .sqlite) {
        if (settings.store.sqlite.dir.slice().len == 0) return refuse(failure, "store.sqlite.dir", "must be anchored");
    } else if (settings.store.mysql.url.bytes.parsed == null) return refuse(failure, "store.mysql.url", "credential source has not been resolved");
    var live: usize = 0;
    inline for (std.enums.values(provider_name.Provider)) |provider| {
        const name = @tagName(provider);
        if (@field(settings.providers.entries, name)) |*entry| {
            if (provider.facts().model_list == .live) live += 1;
            const at = "providers." ++ name;
            const endpoint = if (entry.endpoint) |*url| url.slice() else provider.facts().endpoint;
            endpoint_value.validateEndpoint(endpoint) catch return refuse(failure, at ++ ".endpoint", "invalid provider endpoint");
            if (!entry.unauthenticated.value) {
                switch (comptime provider.facts().credential) {
                    .api_key => {
                        endpoint_value.validateKeyEndpoint(endpoint, if (settings.network.ca_file) |*ca| ca.slice() else null, false) catch return refuse(failure, at ++ ".endpoint", "credentials require HTTPS");
                        if (!secret_value.valid(entry.key.value())) return refuse(failure, at ++ ".key", "credential source has not been resolved");
                    },
                    .sign_in => {
                        if (entry.credential_file == null) return refuse(failure, at ++ ".credentialFile", "credential source has not been resolved");
                        if (!std.mem.eql(u8, endpoint, provider.facts().endpoint)) return refuse(failure, at ++ ".endpoint", "sign-in credentials require the Adapter's own endpoint");
                    },
                }
            }
        }
    }
    if (live > 1) return refuse(failure, "providers", "at most one live model list may be served");
    for (settings.tools.mcp.names[0..settings.tools.mcp.len], settings.tools.mcp.slice()) |*name, *server| {
        var buffer: [start_report.max_refusal_message_bytes / 2]u8 = undefined;
        if (!secret_value.valid(server.bearer_token.value())) return refuse(failure, std.fmt.bufPrint(&buffer, "tools.mcp.{s}.bearerToken", .{name.slice()}) catch unreachable, "credential source has not been resolved");
        _ = http.parseTarget(server.url.slice()) catch return refuse(failure, std.fmt.bufPrint(&buffer, "tools.mcp.{s}.url", .{name.slice()}) catch unreachable, "must be plain HTTP to a loopback literal");
    }
    return .{ .proof = @ptrCast(settings) };
}

// ---- Complete document, streamed without credential bytes --------------------
pub fn write(settings: *const Settings, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try writeValue(Settings, settings, out);
}
fn quoted(text: []const u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try std.json.Stringify.encodeJsonString(text, .{}, out);
}
fn writeOsBytes(bytes: []const u8, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (std.unicode.utf8ValidateSlice(bytes)) return quoted(bytes, out);
    try out.writeAll("{\"hex\":\"");
    try hex_value.write(bytes, out);
    try out.writeAll("\"}");
}
fn writeValue(comptime T: type, value: *const T, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (@typeInfo(T) == .optional) {
        if (value.*) |*present| return writeValue(@typeInfo(T).optional.child, present, out);
        return out.writeAll("null");
    }
    if (comptime isKind(T)) {
        switch (T.kind) {
            .text => try quoted(value.slice(), out),
            .path => if (value.anchored) try out.writeAll("null") else try writeOsBytes(value.slice(), out),
            .url => if (value.slice().len == 0) try out.writeAll("null") else try quoted(value.slice(), out),
            .count => try out.print("{d}", .{value.value}),
            .flag => try out.writeAll(if (value.value) "true" else "false"),
            .choice => try quoted(@tagName(value.value), out),
            .secret => switch (value.source) {
                .default => try out.writeAll("null"),
                .literal => try out.writeAll("{\"owner\":true}"),
                .env => |*name| {
                    try out.writeAll("{\"env\":");
                    try writeOsBytes(name.slice(), out);
                    try out.writeByte('}');
                },
                .file => |*file| {
                    try out.writeAll("{\"file\":");
                    try writeOsBytes(file.slice(), out);
                    try out.writeByte('}');
                },
            },
            .named => {
                try out.writeByte('{');
                for (value.names[0..value.len], value.values[0..value.len], 0..) |*name, *entry, i| {
                    if (i != 0) try out.writeByte(',');
                    try quoted(name.slice(), out);
                    try out.writeByte(':');
                    try writeValue(T.Child, entry, out);
                }
                try out.writeByte('}');
            },
            .providers => {
                try out.writeByte('{');
                var first = true;
                const info = @typeInfo(T.Table).@"struct";
                inline for (info.field_names, info.field_types) |name, Field| {
                    if (@field(value.entries, name) != null) {
                        if (!first) try out.writeByte(',');
                        first = false;
                        try quoted(name, out);
                        try out.writeByte(':');
                        try writeValue(Field, &@field(value.entries, name), out);
                    }
                }
                try out.writeByte('}');
            },
            .presets => {
                try out.writeByte('{');
                for (value.specs, 0..) |preset, i| {
                    if (i != 0) try out.writeByte(',');
                    try quoted(preset.name, out);
                    try out.writeByte(':');
                    try std.json.Stringify.value(std.json.Value{ .object = preset.spec }, .{}, out);
                }
                try out.writeByte('}');
            },
        }
        return;
    }
    try out.writeByte('{');
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types, 0..) |name, Field, i| {
            if (i != 0) try out.writeByte(',');
            try quoted(comptime camel(name), out);
            try out.writeByte(':');
            try writeValue(Field, &@field(value, name), out);
        },
        .@"union" => switch (value.*) {
            inline else => |*payload, tag| {
                try quoted(comptime camel(@tagName(tag)), out);
                try out.writeByte(':');
                try writeValue(@TypeOf(payload.*), payload, out);
            },
        },
        else => @compileError("not a Host settings kind"),
    }
    try out.writeByte('}');
}

// ---- Whole-domain witnesses --------------------------------------------------
fn checkSample(_: std.mem.Allocator, _: std.json.ObjectMap) error{OutOfMemory}!?[]const u8 {
    return null;
}
fn concrete(gpa: std.mem.Allocator, pattern: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (pattern) |byte| if (byte == '*') {
        try out.writer.writeAll("sample");
    } else try out.writer.writeByte(byte);
    return out.toOwnedSlice();
}
fn sampleDocument(gpa: std.mem.Allocator, leaf_path: []const u8, value: []const u8, duplicate: bool) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var parts = std.mem.splitScalar(u8, leaf_path, '.');
    var depth: usize = 0;
    while (parts.next()) |part| {
        try out.writer.writeByte('{');
        depth += 1;
        try quoted(part, &out.writer);
        try out.writer.writeByte(':');
        if (parts.peek() == null) {
            try out.writer.writeAll(value);
            if (duplicate) {
                try out.writer.writeByte(',');
                try quoted(part, &out.writer);
                try out.writer.writeByte(':');
                try out.writer.writeAll(value);
            }
        }
    }
    for (0..depth) |_| try out.writer.writeByte('}');
    return out.toOwnedSlice();
}
fn expectSame(comptime T: type, a: *const T, b: *const T) !void {
    if (@typeInfo(T) == .optional) {
        try std.testing.expectEqual(a.* == null, b.* == null);
        if (a.*) |*present| try expectSame(@typeInfo(T).optional.child, present, &b.*.?);
        return;
    }
    if (comptime isKind(T)) {
        switch (T.kind) {
            .text => try std.testing.expectEqualStrings(a.slice(), b.slice()),
            .path => {
                try std.testing.expectEqual(a.anchored, b.anchored);
                try std.testing.expectEqualStrings(a.slice(), b.slice());
            },
            .url => try std.testing.expectEqualStrings(a.slice(), b.slice()),
            .count, .flag, .choice => try std.testing.expectEqual(a.value, b.value),
            .secret => {
                try std.testing.expectEqual(std.meta.activeTag(a.source), std.meta.activeTag(b.source));
                switch (a.source) {
                    .env => |*name| try std.testing.expectEqualStrings(name.slice(), b.source.env.slice()),
                    .file => |*file| try expectSame(Path, file, &b.source.file),
                    else => {},
                }
                try std.testing.expectEqualStrings(a.value(), b.value());
            },
            .named => {
                try std.testing.expectEqual(a.len, b.len);
                for (a.names[0..a.len], b.names[0..b.len], a.slice(), b.slice()) |*an, *bn, *av, *bv| {
                    try std.testing.expectEqualStrings(an.slice(), bn.slice());
                    try expectSame(T.Child, av, bv);
                }
            },
            .providers => {
                const info = @typeInfo(T.Table).@"struct";
                inline for (info.field_names, info.field_types) |name, Field| try expectSame(Field, &@field(a.entries, name), &@field(b.entries, name));
            },
            .presets => {
                try std.testing.expectEqual(a.specs.len, b.specs.len);
                for (a.specs, b.specs) |av, bv| {
                    try std.testing.expectEqualStrings(av.name, bv.name);
                    const aj = try std.json.Stringify.valueAlloc(std.testing.allocator, std.json.Value{ .object = av.spec }, .{});
                    defer std.testing.allocator.free(aj);
                    const bj = try std.json.Stringify.valueAlloc(std.testing.allocator, std.json.Value{ .object = bv.spec }, .{});
                    defer std.testing.allocator.free(bj);
                    try std.testing.expectEqualStrings(aj, bj);
                }
            },
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| try expectSame(Field, &@field(a, name), &@field(b, name)),
        .@"union" => {
            try std.testing.expectEqual(std.meta.activeTag(a.*), std.meta.activeTag(b.*));
            switch (a.*) {
                inline else => |*payload, tag| {
                    const name = @tagName(tag);
                    try expectSame(@TypeOf(payload.*), payload, &@field(b, name));
                },
            }
        },
        else => @compileError("not a Host settings kind"),
    }
}

test "Host settings every derived leaf agrees across JSON CLI writer and schema" {
    const gpa = std.testing.allocator;
    const a = try gpa.create(Settings);
    defer gpa.destroy(a);
    const b = try gpa.create(Settings);
    defer gpa.destroy(b);
    const c = try gpa.create(Settings);
    defer gpa.destroy(c);
    var visited: [leaves.len]bool = @splat(false);
    const Visitor = struct {
        seen: *[leaves.len]bool,
        pub fn leaf(self: @This(), row: Leaf) !void {
            for (leaves, 0..) |item, i| if (std.mem.eql(u8, item.pattern, row.pattern)) {
                try std.testing.expect(row.doc.len > 0);
                try std.testing.expect(row.sample_json.len > 0);
                self.seen[i] = true;
                return;
            };
            return error.UnexpectedLeaf;
        }
    };
    try schema(Visitor{ .seen = &visited });
    for (leaves, visited) |leaf, seen| {
        try std.testing.expect(seen);
        const at = try concrete(gpa, leaf.pattern);
        defer gpa.free(at);
        const document = try sampleDocument(gpa, at, leaf.sample_json, false);
        defer gpa.free(document);
        a.* = .{};
        defer a.deinit();
        b.* = .{};
        defer b.deinit();
        c.* = .{};
        defer c.deinit();
        var failure: start_report.Failure = undefined;
        errdefer std.debug.print("Host settings leaf: {s}\n", .{at});
        // Providers are a replacing JSON set, but one CLI leaf preserves
        // siblings. Start both witnesses from the same explicit empty set.
        try apply(a, gpa, "{\"providers\":{}}", .pipe, checkSample, &failure);
        try apply(b, gpa, "{\"providers\":{}}", .pipe, checkSample, &failure);
        try apply(a, gpa, document, .pipe, checkSample, &failure);
        try assign(b, gpa, at, leaf.sample_text, checkSample, &failure);
        try expectSame(Settings, a, b);
        var output: std.Io.Writer.Allocating = .init(gpa);
        defer output.deinit();
        try write(a, &output.writer);
        try apply(c, gpa, output.written(), .file, checkSample, &failure);
        try expectSame(Settings, a, c);
    }
}

test "Host settings every derived leaf refuses duplicates wrong kinds and literal file secrets without values" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    for (leaves) |leaf| {
        const at = try concrete(gpa, leaf.pattern);
        defer gpa.free(at);
        settings.* = .{};
        defer settings.deinit();
        var failure: start_report.Failure = undefined;
        const duplicate = try sampleDocument(gpa, at, leaf.sample_json, true);
        defer gpa.free(duplicate);
        try std.testing.expectError(error.SettingsInvalid, apply(settings, gpa, duplicate, .pipe, checkSample, &failure));
        try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), at) != null);
        try std.testing.expectEqual(start_report.StartError.settings_invalid, failure.code);
        const wrong = try sampleDocument(gpa, at, "[]", false);
        defer gpa.free(wrong);
        try std.testing.expectError(error.SettingsInvalid, apply(settings, gpa, wrong, .pipe, checkSample, &failure));
        try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), at) != null);
        if (leaf.secret) {
            const literal = try sampleDocument(gpa, at, "{\"value\":\"DO_NOT_PRINT_THIS_SECRET\"}", false);
            defer gpa.free(literal);
            try std.testing.expectError(error.SettingsInvalid, apply(settings, gpa, literal, .file, checkSample, &failure));
            try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), at) != null);
            try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "DO_NOT_PRINT_THIS_SECRET") == null);
            try std.testing.expectError(error.SettingsInvalid, assign(settings, gpa, at, "DO_NOT_PRINT_THIS_SECRET", checkSample, &failure));
        }
    }
}

test "Host settings unknown paths suggest a derived nearest leaf and never include values" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try std.testing.expectError(error.SettingsInvalid, apply(settings, gpa, "{\"execution\":{\"unknown\":\"DO_NOT_PRINT_THIS_SECRET\"}}", .pipe, checkSample, &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "execution.unknown") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "DO_NOT_PRINT_THIS_SECRET") == null);
    try std.testing.expectError(error.SettingsInvalid, assign(settings, gpa, "tools.bash.timeout", "DO_NOT_PRINT_THIS_SECRET", checkSample, &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), path("tools.bash.timeoutMs")) != null);
}

const max_leaf_path_bytes = blk: {
    var longest: usize = 0;
    for (leaves) |leaf| {
        var len = leaf.pattern.len;
        for (leaf.pattern) |byte| if (byte == '*') {
            len += max_mcp_name_bytes - 1;
        };
        longest = @max(longest, len);
    }
    break :blk longest;
};
fn checkedPath(buffer: *[max_leaf_path_bytes]u8, prefix: []const u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "{s}{s}{s}", .{ prefix, if (prefix.len == 0) "" else ".", name }) catch unreachable;
}
fn validateShape(comptime T: type, value: *const T, at: []const u8, failure: *start_report.Failure) error{SettingsInvalid}!void {
    if (@typeInfo(T) == .optional) {
        if (value.*) |*present| try validateShape(@typeInfo(T).optional.child, present, at, failure);
        return;
    }
    if (comptime isKind(T)) {
        switch (T.kind) {
            .text => if (value.len > T.max_bytes or !std.unicode.utf8ValidateSlice(value.slice()) or std.mem.indexOfScalar(u8, value.slice(), 0) != null) return refuse(failure, at, "invalid UTF-8 text"),
            .path => {
                // An anchored interface uses the platform-derived Host socket,
                // not a literal runtime directory (whose path has a smaller bound).
                if (T.path_rule == .interface and value.anchored) return;
                if (value.text.len > T.max_bytes or std.mem.indexOfScalar(u8, value.slice(), 0) != null or value.anchored or (value.slice().len == 0 and !T.allow_empty) or (T.absolute and !std.fs.path.isAbsolute(value.slice()))) return refuse(failure, at, "must be an anchored absolute path");
            },
            .url => {
                if (value.text.len > T.max_bytes) return refuse(failure, at, "URL exceeds its byte bound");
                switch (T.url_rule) {
                    .https_endpoint => endpoint_value.validateEndpoint(value.slice()) catch return refuse(failure, at, "invalid provider endpoint"),
                    .loopback_http => _ = http.parseTarget(value.slice()) catch return refuse(failure, at, "must be plain HTTP to a loopback literal"),
                }
            },
            .count => if (value.value < T.min or value.value > T.max) return refuse(failure, at, "integer is outside its bounds"),
            .flag, .choice => {},
            .secret => {
                switch (value.source) {
                    .env => |*env| if (env.len > max_secret_env_name_bytes or !validEnv(env.slice())) return refuse(failure, at, "invalid environment variable name"),
                    .file => |*file| try validateShape(Path, file, at, failure),
                    else => {},
                }
                if (T.default_source != .mysql) {
                    if (value.bytes.len > secret_value.max_key_bytes or (value.bytes.len > 0 and !secret_value.valid(value.value()))) return refuse(failure, at, "invalid resolved credential");
                }
            },
            .named => {
                if (value.len > T.max) return refuse(failure, at, "too many named entries");
                for (value.names[0..value.len], value.slice(), 0..) |*name, *entry, i| {
                    var buffer: [max_leaf_path_bytes]u8 = undefined;
                    if (name.len > max_mcp_name_bytes or !validName(name.slice())) return refuse(failure, at, "invalid entry name");
                    for (value.names[0..i]) |*before| if (std.mem.eql(u8, before.slice(), name.slice())) return refuse(failure, at, "duplicate entry name");
                    try validateShape(T.Child, entry, checkedPath(&buffer, at, name.slice()), failure);
                }
            },
            .providers => {
                const info = @typeInfo(T.Table).@"struct";
                inline for (info.field_names, info.field_types) |name, Field| {
                    var buffer: [max_leaf_path_bytes]u8 = undefined;
                    try validateShape(Field, &@field(value.entries, name), checkedPath(&buffer, at, name), failure);
                }
            },
            .presets => {
                if (value.specs.len > preset_value.max_presets) return refuse(failure, at, "too many presets");
                for (value.specs, 0..) |preset, i| {
                    if (!preset_value.validPresetName(preset.name)) return refuse(failure, at, "invalid preset name");
                    for (value.specs[0..i]) |before| if (std.mem.eql(u8, before.name, preset.name)) return refuse(failure, at, "duplicate preset name");
                }
            },
        }
        return;
    }
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| {
            var buffer: [max_leaf_path_bytes]u8 = undefined;
            try validateShape(Field, &@field(value, name), checkedPath(&buffer, at, comptime camel(name)), failure);
        },
        .@"union" => switch (value.*) {
            inline else => |*payload, tag| {
                var buffer: [max_leaf_path_bytes]u8 = undefined;
                try validateShape(@TypeOf(payload.*), payload, checkedPath(&buffer, at, comptime camel(@tagName(tag))), failure);
            },
        },
        else => @compileError("not a Host settings kind"),
    }
}

test "Host settings every derived bounded leaf refuses one byte or integer beyond its owner" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    for (leaves) |leaf| {
        var value: std.Io.Writer.Allocating = .init(gpa);
        defer value.deinit();
        if (std.mem.eql(u8, leaf.kind, "count")) {
            try value.writer.print("{d}", .{@as(u128, leaf.json_schema.max.?) + 1});
        } else if (std.mem.eql(u8, leaf.kind, "path") or std.mem.eql(u8, leaf.kind, "url")) {
            try value.writer.writeByte('"');
            try value.writer.writeAll(if (std.mem.eql(u8, leaf.kind, "path")) "/" else if (std.mem.eql(u8, leaf.json_schema.format.?, "loopback_http")) "http://127.0.0.1/" else "https://example.test/");
            try value.writer.splatByteAll('a', leaf.json_schema.max_bytes.? + 1);
            try value.writer.writeByte('"');
        } else if (leaf.secret) {
            try value.writer.writeAll("{\"value\":\"");
            if (std.mem.eql(u8, leaf.json_schema.format.?, "mysql-login-source")) {
                try value.writer.writeAll("mysql://u:");
                const capacity = comptime @as(MysqlValue, .{}).password.bytes.len;
                try value.writer.splatByteAll('a', capacity + 1);
                try value.writer.writeAll("@localhost/db");
            } else try value.writer.splatByteAll('a', secret_value.max_key_bytes + 1);
            try value.writer.writeAll("\"}");
        } else continue;
        const at = try concrete(gpa, leaf.pattern);
        defer gpa.free(at);
        const doc = try sampleDocument(gpa, at, value.written(), false);
        defer gpa.free(doc);
        settings.* = .{};
        defer settings.deinit();
        var failure: start_report.Failure = undefined;
        try std.testing.expectError(error.SettingsInvalid, apply(settings, gpa, doc, .pipe, checkSample, &failure));
        try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), at) != null);
        try std.testing.expectError(error.SettingsInvalid, assign(settings, gpa, at, value.written(), checkSample, &failure));
    }
}

test "Host settings named sets replace and removed credentials are wiped" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    inline for (@typeInfo(provider_name.Provider).@"enum".field_names) |name| try std.testing.expect(@field(settings.providers.entries, name) != null);
    try apply(settings, gpa, "{\"providers\":{},\"tools\":{\"mcp\":{\"old\":{\"url\":\"http://127.0.0.1/mcp\",\"bearerToken\":{\"value\":\"WIPE_THIS_TOKEN\"}}}}}", .pipe, checkSample, &failure);
    inline for (@typeInfo(provider_name.Provider).@"enum".field_names) |name| try std.testing.expect(@field(settings.providers.entries, name) == null);
    try std.testing.expectEqual(@as(usize, 1), settings.tools.mcp.len);
    try apply(settings, gpa, "{\"execution\":{\"paused\":true}}", .pipe, checkSample, &failure);
    try std.testing.expectEqualStrings("WIPE_THIS_TOKEN", settings.tools.mcp.values[0].bearer_token.value());
    try apply(settings, gpa, "{\"tools\":{\"mcp\":{}}}", .pipe, checkSample, &failure);
    try std.testing.expectEqual(@as(usize, 0), settings.tools.mcp.len);
    for (settings.tools.mcp.values[0].bearer_token.bytes.bytes) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    // Incremental CLI edits preserve other entries; removing one shifts in
    // place and leaves no second owner in the vacated slot.
    try assign(settings, gpa, "tools.mcp.first.bearerToken", "env:FIRST", checkSample, &failure);
    try assign(settings, gpa, "tools.mcp.second.bearerToken", "env:SECOND", checkSample, &failure);
    try assign(settings, gpa, "tools.mcp.first", "null", checkSample, &failure);
    try std.testing.expectEqual(@as(usize, 1), settings.tools.mcp.len);
    try std.testing.expectEqualStrings("second", settings.tools.mcp.names[0].slice());
    var set: std.Io.Writer.Allocating = .init(gpa);
    defer set.deinit();
    try set.writer.writeAll("{\"tools\":{\"mcp\":{");
    for (0..max_mcp_servers + 1) |i| {
        if (i != 0) try set.writer.writeByte(',');
        try set.writer.print("\"server{d}\":{{}}", .{i});
    }
    try set.writer.writeAll("}}}");
    try std.testing.expectError(error.SettingsInvalid, apply(settings, gpa, set.written(), .pipe, checkSample, &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "tools.mcp") != null);
}

test "Host settings anchor and seal require explicit MySQL interface and resolved sources" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try apply(settings, gpa, "{\"providers\":{}}", .pipe, checkSample, &failure);
    try std.testing.expectError(error.SettingsInvalid, seal(settings, &failure));
    try anchor(settings, "/tmp/host-settings/");
    const prepared = try seal(settings, &failure);
    try std.testing.expect(prepared.get() == settings);
    try std.testing.expectEqualStrings("/tmp/host-settings", settings.store.sqlite.dir.slice());
    try std.testing.expect(settings.interface.dir.anchored);
    settings.interface.dir.anchored = true;
    try assign(settings, gpa, "store.mysql.url", "env:DATABASE_URL", checkSample, &failure);
    try std.testing.expectError(error.SettingsInvalid, anchor(settings, "/tmp/host-settings"));
    try assign(settings, gpa, "interface.dir", "/tmp/host-settings///", checkSample, &failure);
    try std.testing.expectEqualStrings("/tmp/host-settings", settings.interface.dir.slice());
    try anchor(settings, "/tmp/host-settings");
    try std.testing.expectError(error.SettingsInvalid, seal(settings, &failure));
    try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), "store.mysql.url") != null);
    try settings.store.mysql.url.bytes.set(gpa, "mysql://user:@localhost/db");
    _ = try seal(settings, &failure);
    try assign(settings, gpa, "execution.activeCapacity", "1", checkSample, &failure);
    settings.tools.bash.timeout_ms.value = 0;
    try std.testing.expectError(error.SettingsInvalid, seal(settings, &failure));
    settings.tools.bash.timeout_ms.value = default_bash_timeout_ms;
    settings.tools.mcp.len = max_mcp_servers + 1;
    try std.testing.expectError(error.SettingsInvalid, seal(settings, &failure));
    settings.tools.mcp.len = 0;
}

test "Host settings every derived provider credential respects resolution redaction and destination" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    const restored = try gpa.create(Settings);
    defer gpa.destroy(restored);
    inline for (std.enums.values(provider_name.Provider)) |provider| {
        const name = @tagName(provider);
        settings.* = .{};
        defer settings.deinit();
        restored.* = .{};
        defer restored.deinit();
        var failure: start_report.Failure = undefined;
        try apply(settings, gpa, "{\"providers\":{\"" ++ name ++ "\":{}}}", .pipe, checkSample, &failure);
        try anchor(settings, "/tmp/host-settings");
        const entry = &@field(settings.providers.entries, name).?;
        if (comptime provider.facts().credential == .api_key) {
            try std.testing.expectError(error.SettingsInvalid, seal(settings, &failure));
            try apply(settings, gpa, "{\"providers\":{\"" ++ name ++ "\":{\"key\":{\"value\":\"SECRET_SENTINEL\"}}}}", .pipe, checkSample, &failure);
            _ = try seal(settings, &failure);
            var output: std.Io.Writer.Allocating = .init(gpa);
            defer output.deinit();
            try write(settings, &output.writer);
            try std.testing.expect(std.mem.indexOf(u8, output.written(), "SECRET_SENTINEL") == null);
            try std.testing.expect(std.mem.indexOf(u8, output.written(), "\"owner\":true") != null);
            try apply(restored, gpa, output.written(), .file, checkSample, &failure);
            try std.testing.expectError(error.SettingsInvalid, seal(restored, &failure));
        } else {
            try std.testing.expectError(error.SettingsInvalid, seal(settings, &failure));
            try assign(settings, gpa, "providers." ++ name ++ ".credentialFile", "/tmp/sign-in.json", checkSample, &failure);
            _ = try seal(settings, &failure);
        }
        try assign(settings, gpa, "providers." ++ name ++ ".endpoint", "http://127.0.0.1:3000/responses", checkSample, &failure);
        try std.testing.expectError(error.SettingsInvalid, seal(settings, &failure));
        entry.unauthenticated.value = true;
        _ = try seal(settings, &failure);
        try assign(settings, gpa, "providers." ++ name, "null", checkSample, &failure);
        try std.testing.expect(@field(settings.providers.entries, name) == null);
    }
}

test "Host settings MySQL literal exceeds API key size but never appears in output" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var input: std.Io.Writer.Allocating = .init(gpa);
    defer input.deinit();
    try input.writer.writeAll("{\"providers\":{},\"interface\":{\"dir\":\"/tmp/host-settings\"},\"store\":{\"mysql\":{\"url\":{\"value\":\"mysql://user:");
    try input.writer.splatByteAll('p', comptime @as(MysqlValue, .{}).password.bytes.len);
    try input.writer.writeAll("@localhost/db\"}}}}");
    var failure: start_report.Failure = undefined;
    try apply(settings, gpa, input.written(), .pipe, checkSample, &failure);
    try std.testing.expect(settings.store.mysql.url.value().len > secret_value.max_key_bytes);
    _ = try seal(settings, &failure);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try write(settings, &output.writer);
    try std.testing.expect(std.mem.indexOf(u8, output.written(), "mysql://user:") == null);
    // Switching the one-Adapter Seam disposes the whole login.
    try assign(settings, gpa, "store.sqlite.dir", "/tmp/sqlite", checkSample, &failure);
    try std.testing.expect(settings.store == .sqlite);
}

test "Host settings strict JSON rejects malformed escaped duplicates and excessive nesting" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    for ([_][]const u8{ "{", "[]", "{}{}", "{\"execution\":{\"paused\":true,}}", "{\"execution\":{\"paused\":true,\"p\\u0061used\":false}}", "{\"execution\":{\"activeCapacity\":1.0}}" }) |input| {
        try std.testing.expectError(error.SettingsInvalid, apply(settings, gpa, input, .pipe, checkSample, &failure));
    }
    var deep: std.Io.Writer.Allocating = .init(gpa);
    defer deep.deinit();
    try deep.writer.writeAll("{\"presets\":{\"reader\":{\"instructions\":");
    for (0..protocol.max_json_depth + 1) |_| try deep.writer.writeByte('[');
    try deep.writer.writeAll("null");
    for (0..protocol.max_json_depth + 1) |_| try deep.writer.writeByte(']');
    try deep.writer.writeAll("}}}");
    try std.testing.expectError(error.SettingsInvalid, apply(settings, gpa, deep.written(), .pipe, checkSample, &failure));
    const oversized = try gpa.alloc(u8, max_document_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, ' ');
    try std.testing.expectError(error.SettingsInvalid, apply(settings, gpa, oversized, .pipe, checkSample, &failure));
}

test "Host settings name kind covers its byte domain and Text uses UTF-8 byte bounds" {
    try std.testing.expect(!validName(""));
    try std.testing.expect(validName(&@as([max_mcp_name_bytes]u8, @splat('A'))));
    try std.testing.expect(!validName(&@as([max_mcp_name_bytes + 1]u8, @splat('A'))));
    for (0..256) |n| {
        const byte: u8 = @intCast(n);
        const expected = (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or (byte >= '0' and byte <= '9') or byte == '_' or byte == '-';
        try std.testing.expectEqual(expected, validName(&.{byte}));
    }
    var text: Text("é".len) = .{};
    try text.set("é");
    try std.testing.expectEqualStrings("é", text.slice());
    try std.testing.expectError(error.SettingsInvalid, text.set("éx"));
    try std.testing.expectError(error.SettingsInvalid, text.set("\xc3"));
    try std.testing.expectError(error.SettingsInvalid, text.set("\x00"));
}

test "Host settings JSON nesting accepts the owner bound and refuses the next container" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    const prefix = "{\"presets\":{\"reader\":{\"outputSchema\":";
    const surrounding = comptime std.mem.count(u8, prefix, "{");
    for ([_]usize{ protocol.max_json_depth - surrounding, protocol.max_json_depth - surrounding + 1 }, 0..) |arrays, i| {
        var input: std.Io.Writer.Allocating = .init(gpa);
        defer input.deinit();
        try input.writer.writeAll(prefix);
        for (0..arrays) |_| try input.writer.writeByte('[');
        try input.writer.writeAll("null");
        for (0..arrays) |_| try input.writer.writeByte(']');
        try input.writer.writeAll("}}}");
        var failure: start_report.Failure = undefined;
        if (i == 0) try apply(settings, gpa, input.written(), .pipe, checkSample, &failure) else try std.testing.expectError(error.SettingsInvalid, apply(settings, gpa, input.written(), .pipe, checkSample, &failure));
    }
}

test "Host settings schema derives container constraints and every leaf parent" {
    const Visitor = struct {
        group_count: usize = 0,
        leaf_count: usize = 0,
        pub fn group(self: *@This(), row: Group) !void {
            self.group_count += 1;
            try std.testing.expect(row.doc.len > 0);
            switch (row.kind) {
                .object => try std.testing.expect(row.keys.len > 0),
                .one_adapter => {
                    try std.testing.expectEqual(@as(usize, 1), row.min_entries);
                    try std.testing.expectEqual(@as(?usize, 1), row.max_entries);
                },
                .providers => try std.testing.expectEqual(std.enums.values(provider_name.Provider).len, row.max_entries.?),
                .named => switch (row.name_format.?) {
                    .mcp => {
                        try std.testing.expectEqual(max_mcp_servers, row.max_entries.?);
                        try std.testing.expectEqual(max_mcp_name_bytes, row.name_max_bytes.?);
                    },
                    .preset => {
                        try std.testing.expectEqual(preset_value.max_presets, row.max_entries.?);
                        try std.testing.expectEqual(preset_value.max_preset_name_bytes, row.name_max_bytes.?);
                    },
                },
            }
        }
        pub fn leaf(self: *@This(), row: Leaf) !void {
            self.leaf_count += 1;
            const dot = std.mem.lastIndexOfScalar(u8, row.pattern, '.') orelse return error.MissingParent;
            for (groups) |parent| if (std.mem.eql(u8, row.pattern[0..dot], parent.pattern)) return;
            return error.MissingParent;
        }
    };
    var visitor: Visitor = .{};
    try schema(&visitor);
    try std.testing.expectEqual(groups.len, visitor.group_count);
    try std.testing.expectEqual(leaves.len, visitor.leaf_count);
    try std.testing.expectEqualStrings("", groups[0].pattern);
    try std.testing.expectEqual(@typeInfo(Settings).@"struct".field_names.len, groups[0].keys.len);
}

test "Host settings defaults and anchored defaults round trip as complete documents" {
    const gpa = std.testing.allocator;
    const original = try gpa.create(Settings);
    defer gpa.destroy(original);
    const restored = try gpa.create(Settings);
    defer gpa.destroy(restored);
    for ([_]bool{ false, true }) |anchored| {
        original.* = .{};
        defer original.deinit();
        restored.* = .{};
        defer restored.deinit();
        if (anchored) try anchor(original, "/tmp/host-settings");
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try write(original, &out.writer);
        var failure: start_report.Failure = undefined;
        try apply(restored, gpa, out.written(), .file, checkSample, &failure);
        try expectSame(Settings, original, restored);
    }
}

test "Host settings default interface preserves derived socket routing for long Store paths" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try apply(settings, gpa, "{\"providers\":{}}", .file, checkSample, &failure);
    const host_dir = "/tmp/" ++ @as([max_runtime_dir_bytes]u8, @splat('h'));
    try anchor(settings, host_dir);
    try std.testing.expect(settings.interface.dir.anchored);
    _ = try seal(settings, &failure);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(settings, &out.writer);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"dir\":null") != null);
}

test "Host settings preserve existing relative Store Bash and provider CA paths" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try apply(settings, gpa, "{\"providers\":{}}", .file, checkSample, &failure);
    for ([_][]const u8{ "store.sqlite.dir", "tools.bash.path", "network.caFile" }) |leaf| {
        try assign(settings, gpa, leaf, "relative/path", checkSample, &failure);
    }
    try anchor(settings, "/tmp/host-settings");
    _ = try seal(settings, &failure);
    try std.testing.expectEqualStrings("relative/path", settings.store.sqlite.dir.slice());
    try std.testing.expectEqualStrings("relative/path", settings.tools.bash.path.slice());
    try std.testing.expectEqualStrings("relative/path", settings.network.ca_file.?.slice());
    try std.testing.expectError(error.SettingsInvalid, assign(settings, gpa, "interface.dir", "relative/path", checkSample, &failure));
}

test "Host settings admit the existing provider-free zero active capacity" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try apply(settings, gpa, "{\"providers\":{}}", .file, checkSample, &failure);
    try assign(settings, gpa, "execution.activeCapacity", "0", checkSample, &failure);
    try anchor(settings, "/tmp/host-settings");
    _ = try seal(settings, &failure);
    try std.testing.expectEqual(@as(usize, 0), settings.execution.active_capacity.value);
}

test "Host settings proof requires each served sign-in path to be resolved" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    inline for (std.enums.values(provider_name.Provider)) |provider| {
        if (comptime provider.facts().credential == .sign_in) {
            settings.* = .{};
            defer settings.deinit();
            var failure: start_report.Failure = undefined;
            try apply(settings, gpa, "{\"providers\":{\"" ++ @tagName(provider) ++ "\":{}}}", .file, checkSample, &failure);
            try anchor(settings, "/tmp/host-settings");
            try std.testing.expectError(error.SettingsInvalid, seal(settings, &failure));
            try assign(settings, gpa, "providers." ++ @tagName(provider) ++ ".credentialFile", "/tmp/sign-in.json", checkSample, &failure);
            _ = try seal(settings, &failure);
        }
    }
}

test "Host settings retain the legacy empty CA path for transport refusal" {
    const gpa = std.testing.allocator;
    const settings = try gpa.create(Settings);
    defer gpa.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    try apply(settings, gpa, "{\"providers\":{},\"network\":{\"caFile\":\"\"}}", .file, checkSample, &failure);
    try anchor(settings, "/tmp/host-settings");
    _ = try seal(settings, &failure);
    try std.testing.expect(settings.network.ca_file != null);
    try std.testing.expectEqualStrings("", settings.network.ca_file.?.slice());
}

/// Scan full backing storage, including inactive slots and bytes beyond len.
/// Released blocks are observed too: a MySQL secret lives outside Settings.
const VacancyWitness = struct {
    const marker = "HOST_SETTINGS_SECRET_VACANCY_SENTINEL";
    const mysql_login = "mysql://user:" ++ marker ++ "@localhost/database";
    const Action = enum {
        env,
        file,
        default,
        owner,
        shorter_literal,
        entry_null,
        entry_readd,
        whole_empty,
        whole_populated,
        store_roundtrip,
        presets_replace,
        refusal_apply,
        refusal_assign,
        wipe,
        deinit,
    };
    const Releases = struct {
        child: std.mem.Allocator,
        stale: usize = 0,
        frees: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
        }
        fn alloc(ptr: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.child.rawAlloc(len, alignment, ret);
        }
        fn free(ptr: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.stale += copies(bytes);
            self.frees += 1;
            self.child.rawFree(bytes, alignment, ret);
        }
    };
    fn copies(bytes: []const u8) usize {
        return std.mem.count(u8, bytes, marker);
    }
    fn mysqlCopies(bytes: *const MysqlBytes) usize {
        return copies(bytes.raw) + if (bytes.parsed) |parsed| copies(std.mem.asBytes(parsed)) else @as(usize, 0);
    }
    fn expectCopies(settings: *const Settings, expected: usize) !void {
        var count = copies(std.mem.asBytes(settings));
        if (settings.store == .mysql) count += mysqlCopies(&settings.store.mysql.url.bytes);
        try std.testing.expectEqual(expected, count);
    }
    fn markTails(comptime T: type, value: *T) void {
        if (@typeInfo(T) == .optional) {
            if (value.*) |*present| markTails(@typeInfo(T).optional.child, present);
        } else if (comptime isKind(T)) {
            switch (T.kind) {
                .secret => if (T.default_source == .mysql) {
                    if (value.bytes.parsed) |parsed| @memcpy(parsed.password.bytes[parsed.password.bytes.len - marker.len ..], marker);
                } else if (value.bytes.len != 0) {
                    @memcpy(value.bytes.bytes[value.bytes.bytes.len - marker.len ..], marker);
                },
                .providers => markTails(T.Table, &value.entries),
                .named => for (&value.values) |*entry| markTails(T.Child, entry),
                else => {},
            }
        } else switch (@typeInfo(T)) {
            .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| markTails(Field, &@field(value, name)),
            .@"union" => switch (value.*) {
                inline else => |*payload| markTails(@TypeOf(payload.*), payload),
            },
            else => unreachable,
        }
    }
    fn checkedApply(settings: *Settings, gpa: std.mem.Allocator, doc: []const u8, failure: *start_report.Failure) !void {
        apply(settings, gpa, doc, .pipe, checkSample, failure) catch |err| {
            try expectCopies(settings, 0);
            return err;
        };
    }
    fn checkedAssign(settings: *Settings, gpa: std.mem.Allocator, at: []const u8, input: []const u8, failure: *start_report.Failure) !void {
        assign(settings, gpa, at, input, checkSample, failure) catch |err| {
            try expectCopies(settings, 0);
            return err;
        };
    }
    fn document(settings: *Settings, gpa: std.mem.Allocator, at: []const u8, input: []const u8, failure: *start_report.Failure) !void {
        const doc = @constCast(try sampleDocument(std.testing.allocator, at, input, false));
        defer {
            std.crypto.secureZero(u8, doc);
            std.testing.allocator.free(doc);
        }
        try checkedApply(settings, gpa, doc, failure);
    }
    fn exercise(comptime leaf: Leaf, action: Action, seed_gpa: std.mem.Allocator, operation_gpa: std.mem.Allocator) !void {
        const settings = try seed_gpa.create(Settings);
        defer seed_gpa.destroy(settings);
        std.crypto.secureZero(u8, std.mem.asBytes(settings));
        settings.* = .{};
        defer settings.deinit();
        const at = try concrete(std.testing.allocator, leaf.pattern);
        defer std.testing.allocator.free(at);
        const parent = at[0..std.mem.lastIndexOfScalar(u8, at, '.').?];
        const set = parent[0..std.mem.lastIndexOfScalar(u8, parent, '.').?];
        const name = parent[set.len + 1 ..];
        const is_mysql = comptime std.mem.eql(u8, leaf.json_schema.format.?, "mysql-login-source");
        const literal = if (is_mysql) "{\"value\":\"" ++ mysql_login ++ "\"}" else "{\"value\":\"" ++ marker ++ "\"}";
        var failure: start_report.Failure = undefined;
        // Secret vacancy must be independent of the new path rules. Seed
        // relative/empty paths through apply, then an OS-byte path via assign.
        try apply(settings, seed_gpa, "{\"tools\":{\"bash\":{\"path\":\"relative/bash\"}},\"network\":{\"caFile\":\"\"}}", .file, checkSample, &failure);
        try assign(settings, seed_gpa, "tools.bash.path", "relative/bash-\xff", checkSample, &failure);
        try document(settings, seed_gpa, at, literal, &failure);
        markTails(Settings, settings);
        const live_copies: usize = if (is_mysql) 3 else 2;
        try expectCopies(settings, live_copies);
        switch (action) {
            .env => try checkedAssign(settings, operation_gpa, at, "env:NEW_\xff", &failure),
            .file => try checkedAssign(settings, operation_gpa, at, "file:/tmp/new-\xff", &failure),
            .default => try checkedAssign(settings, operation_gpa, at, "null", &failure),
            .owner => try checkedAssign(settings, operation_gpa, at, "{\"owner\":true}", &failure),
            .shorter_literal => try document(settings, operation_gpa, at, if (is_mysql) "{\"value\":\"mysql://u:x@localhost/db\"}" else "{\"value\":\"x\"}", &failure),
            .entry_null, .entry_readd, .store_roundtrip => {
                if (is_mysql) {
                    if (action == .entry_null) {
                        try document(settings, operation_gpa, "store", "{\"sqlite\":{}}", &failure);
                    } else try checkedAssign(settings, operation_gpa, "store.sqlite", "{}", &failure);
                } else try checkedAssign(settings, operation_gpa, parent, "null", &failure);
                try expectCopies(settings, 0);
                if (action != .entry_null) try checkedAssign(settings, operation_gpa, at, "env:NEW_\xff", &failure);
            },
            .whole_empty => if (is_mysql) {
                try checkedAssign(settings, operation_gpa, "store.sqlite", "{}", &failure);
            } else try document(settings, operation_gpa, set, "{}", &failure),
            .whole_populated => if (is_mysql) {
                try document(settings, operation_gpa, at, "{\"value\":\"mysql://u:x@localhost/db\"}", &failure);
            } else {
                const replacement = try std.fmt.allocPrint(std.testing.allocator, "{{\"{s}\":{{}}}}", .{name});
                defer std.testing.allocator.free(replacement);
                try document(settings, operation_gpa, set, replacement, &failure);
            },
            .presets_replace => {
                try checkedApply(settings, operation_gpa, "{\"presets\":{\"first\":{\"model\":\"retained\"}}}", &failure);
                try checkedApply(settings, operation_gpa, "{\"presets\":{\"second\":{\"model\":\"replacement\"}}}", &failure);
                try checkedApply(settings, operation_gpa, "{\"presets\":{}}", &failure);
                try expectCopies(settings, live_copies);
                settings.wipe();
            },
            .refusal_apply => {
                const outcome = checkedApply(settings, operation_gpa, "{\"execution\":{\"unknown\":true}}", &failure);
                if (outcome) |_| return error.ExpectedRefusal else |err| if (err != error.SettingsInvalid) return err;
            },
            .refusal_assign => {
                const outcome = checkedAssign(settings, operation_gpa, "unknown", "true", &failure);
                if (outcome) |_| return error.ExpectedRefusal else |err| if (err != error.SettingsInvalid) return err;
            },
            .wipe => settings.wipe(),
            .deinit => settings.deinit(),
        }
        try expectCopies(settings, 0);
    }
    fn runActions(seed_gpa: std.mem.Allocator, operation_gpa: std.mem.Allocator) !void {
        inline for (leaves) |leaf| if (leaf.secret) {
            for (std.enums.values(Action)) |action| try exercise(leaf, action, seed_gpa, operation_gpa);
        };
    }
    fn namedMoves(comptime Child: type, releases: *Releases) !void {
        const Set = if (Child == McpServer) @FieldType(Tools, "mcp") else Named(3, Child);
        const Owner = if (Child == McpServer) Settings else Set;
        const gpa = releases.allocator();
        for ([_]usize{ 1, 2, 3, Set.max }) |population| for (0..population) |removed| {
            const owner = try gpa.create(Owner);
            defer gpa.destroy(owner);
            std.crypto.secureZero(u8, std.mem.asBytes(owner));
            owner.* = .{};
            defer dispose(Owner, owner);
            const values = if (Child == McpServer) &owner.tools.mcp else owner;
            var failure: start_report.Failure = undefined;
            var memory: std.heap.ArenaAllocator = .init(gpa);
            defer memory.deinit();
            const read: Read = .{ .arena = memory.allocator(), .gpa = gpa, .origin = .pipe, .check = checkSample, .failure = &failure };
            for (0..population) |i| {
                var name: [32]u8 = undefined;
                try values.names[i].set(try std.fmt.bufPrint(&name, "entry{d}", .{i}));
                values.len += 1;
                const key = if (Child == McpServer) &values.values[i].bearer_token else &values.values[i].key;
                @memcpy(key.bytes.bytes[0..marker.len], marker);
                key.bytes.len = marker.len;
                key.source = .literal;
                if (Child != McpServer) {
                    try values.values[i].login.bytes.set(gpa, mysql_login);
                    values.values[i].retained.memory = .init(gpa);
                    _ = try values.values[i].retained.memory.?.allocator().dupe(u8, "retained preset allocation");
                }
            }
            markTails(Set, values);
            var name: [32]u8 = undefined;
            const at = try std.fmt.bufPrint(&name, "entry{d}", .{removed});
            if (Child == McpServer) {
                var path_buffer: [64]u8 = undefined;
                try checkedAssign(owner, gpa, try std.fmt.bufPrint(&path_buffer, "tools.mcp.{s}", .{at}), "null", &failure);
            } else try assignAt(Set, values, at, "null", at, &read);
            try std.testing.expectEqual(population - 1, values.len);
            var total = copies(std.mem.asBytes(owner));
            for (values.values[0..values.len], 0..) |*entry, i| {
                try std.testing.expectEqualStrings(try std.fmt.bufPrint(&name, "entry{d}", .{if (i < removed) i else i + 1}), values.names[i].slice());
                const key = if (Child == McpServer) &entry.bearer_token else &entry.key;
                try std.testing.expectEqualStrings(marker, key.value());
                if (Child != McpServer) {
                    try std.testing.expectEqualStrings(mysql_login, entry.login.value());
                    try std.testing.expectEqualStrings(marker, entry.login.bytes.parsed.?.password.slice());
                    total += mysqlCopies(&entry.login.bytes);
                }
            }
            try std.testing.expectEqual((population - 1) * @as(usize, if (Child == McpServer) 2 else 5), total);
            // Reuse vacated capacity, then replace and empty the whole set.
            const key_name = if (Child == McpServer) "bearerToken" else "key";
            try assignAt(Set, values, "replacement." ++ key_name, "env:NEW_\xff", "replacement." ++ key_name, &read);
            try std.testing.expectEqual(population, values.len);
            try readValue(Set, values, try parseJson(&read, "{\"new\":{}}", "set"), "set", &read);
            try std.testing.expectEqual(@as(usize, 0), copies(std.mem.asBytes(owner)));
            try readValue(Set, values, .{ .object = .{} }, "set", &read);
            try std.testing.expectEqual(@as(usize, 0), copies(std.mem.asBytes(owner)));
            try std.testing.expectEqual(@as(usize, 0), values.len);
        };
    }
};

test "Host settings every secret vacancy erases all stored copies" {
    var releases: VacancyWitness.Releases = .{ .child = std.testing.allocator };
    try VacancyWitness.runActions(releases.allocator(), releases.allocator());
    try VacancyWitness.namedMoves(McpServer, &releases);
    // Exercise the generic transfer with resource-owning V as well as MCP.
    try VacancyWitness.namedMoves(struct {
        key: Secret(.required) = .{},
        login: Secret(.mysql) = .{},
        retained: Presets = .{},
    }, &releases);
    try std.testing.expect(releases.frees > 0);
    try std.testing.expectEqual(@as(usize, 0), releases.stale);
}

/// Cross-root witnesses only; no testing surface is present in production.
/// The non-core test root owns the allocation-failure injector.
pub const testing = if (@import("builtin").is_test) struct {
    pub fn secretVacancyAllocationFailures(gpa: std.mem.Allocator) !void {
        // Seed outside injection: even operation allocation zero starts with
        // resolved credentials. Observe both old and new allocation release.
        var seed: VacancyWitness.Releases = .{ .child = std.testing.allocator };
        var operation: VacancyWitness.Releases = .{ .child = gpa };
        const outcome = VacancyWitness.runActions(seed.allocator(), operation.allocator());
        try std.testing.expectEqual(@as(usize, 0), seed.stale);
        try std.testing.expectEqual(@as(usize, 0), operation.stale);
        return outcome;
    }
} else struct {};

// The generated path domain includes optional provider credential paths, not
// just the few paths currently exposed as flags.
test "Host settings every Path leaf round trips OS bytes and allowed path rules" {
    const gpa = std.testing.allocator;
    const a = try gpa.create(Settings);
    defer gpa.destroy(a);
    const b = try gpa.create(Settings);
    defer gpa.destroy(b);
    for (leaves) |leaf| {
        if (!std.mem.eql(u8, leaf.kind, "path")) continue;
        try std.testing.expectEqual(.one_of, leaf.json_schema.type);
        try std.testing.expectEqual(@as(usize, 2), leaf.json_schema.one_of.len);
        try std.testing.expect(leaf.json_schema.hex_object.?.required);
        try std.testing.expect(!leaf.json_schema.hex_object.?.additional_properties);
        try std.testing.expectEqual(leaf.json_schema.max_bytes.? * 2, leaf.json_schema.hex_object.?.max_length);
        const at = try concrete(gpa, leaf.pattern);
        defer gpa.free(at);
        const candidates = [_][]const u8{ "/tmp/utf8", "/tmp/\xff", "relative/path", "", "{raw-path", "null" };
        for (candidates, 0..) |candidate, index| {
            if (index >= 2 and leaf.json_schema.format != null) continue;
            if (candidate.len == 0 and !leaf.json_schema.path_accepts_empty) continue;
            a.* = .{};
            defer a.deinit();
            b.* = .{};
            defer b.deinit();
            var failure: start_report.Failure = undefined;
            try apply(a, gpa, "{\"providers\":{}}", .file, checkSample, &failure);
            try assign(a, gpa, at, candidate, checkSample, &failure);
            try anchor(a, "/tmp/path-roundtrip");
            _ = try seal(a, &failure);
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try write(a, &out.writer);
            if (index == 1) try std.testing.expect(std.mem.indexOf(u8, out.written(), "{\"hex\":\"2f746d702fff\"}") != null);
            try apply(b, gpa, out.written(), .file, checkSample, &failure);
            try expectSame(Settings, a, b);
            try std.testing.expect(std.unicode.utf8ValidateSlice(out.written()));
        }
        for ([_][]const u8{ "{\"hex\":\"FF\"}", "{\"hex\":\"0\"}", "{\"hex\":\"gg\"}", "{\"hex\":\"00\"}", "{\"hex\":\"2fff\",\"unknown\":true}" }) |bad| {
            a.* = .{};
            defer a.deinit();
            var failure: start_report.Failure = undefined;
            const document = try sampleDocument(gpa, at, bad, false);
            defer gpa.free(document);
            try std.testing.expectError(error.SettingsInvalid, apply(a, gpa, document, .file, checkSample, &failure));
            try std.testing.expect(std.mem.indexOf(u8, failure.message.slice(), at) != null);
        }
    }
}

test "Host settings secret file and environment sources preserve OS bytes" {
    const gpa = std.testing.allocator;
    const a = try gpa.create(Settings);
    defer gpa.destroy(a);
    const b = try gpa.create(Settings);
    defer gpa.destroy(b);
    for (leaves) |leaf| {
        if (!leaf.secret) continue;
        const at = try concrete(gpa, leaf.pattern);
        defer gpa.free(at);
        for ([_][]const u8{ "file:/tmp/\xff", "env:KEY_\xff" }) |source| {
            a.* = .{};
            defer a.deinit();
            b.* = .{};
            defer b.deinit();
            var failure: start_report.Failure = undefined;
            try assign(a, gpa, at, source, checkSample, &failure);
            var out: std.Io.Writer.Allocating = .init(gpa);
            defer out.deinit();
            try write(a, &out.writer);
            try std.testing.expect(std.unicode.utf8ValidateSlice(out.written()));
            try apply(b, gpa, out.written(), .file, checkSample, &failure);
            try expectSame(Settings, a, b);
        }
    }
}
