//! A connection: one server, one credential, the wire formats that server
//! speaks, and which models use which format. The settings document's
//! `connections` entries parse here, and the bundled presets are documents in
//! the same format, read by the same parser. Pure: text in, a checked value or
//! a refusal out. This file owns the rules a connection must satisfy
//! (`validate`) and the one choice of format and request URL per model
//! (`resolve`).

const std = @import("std");
const provider_name = @import("provider_name.zig");
const endpoint_value = @import("endpoint_value.zig");

pub const max_document_bytes = 16 * 1024;
pub const max_name_bytes = 16;
pub const max_label_bytes = 40;
pub const max_identifier_bytes = 64;
pub const max_refusal_body_bytes = 200;

// ---------------------------------------------------------------- names and formats

/// A connection's identity: the chat binding, the CLI spelling, the custody
/// file. Same grammar as the Store's provider column, so a Session binds to
/// it without a format change. Never renamed.
pub const Name = struct {
    bytes: [max_name_bytes]u8,
    len: u8,

    pub fn parse(text: []const u8) ?Name {
        if (text.len == 0 or text.len > max_name_bytes) return null;
        if (!std.ascii.isLower(text[0])) return null;
        for (text) |byte| {
            if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and byte != '-') return null;
        }
        var name: Name = .{ .bytes = @splat(0), .len = @intCast(text.len) };
        @memcpy(name.bytes[0..text.len], text);
        return name;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Name, other: Name) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }

    /// Two optional names are the same when both are absent or both are present and equal.
    pub fn eqlOptional(a: ?Name, b: ?Name) bool {
        const left = a orelse return b == null;
        const right = b orelse return false;
        return left.eql(right);
    }
};

/// A wire-format family: the shape of request and response bytes, without a
/// version. A person chooses a family; the dialect is part of the format.
pub const Family = enum {
    responses,
    messages,

    pub fn defaultPath(self: Family) []const u8 {
        return switch (self) {
            .responses => "/responses",
            .messages => "/messages",
        };
    }
};

/// The exact dialect a Session pins: the provider's codec owner, not a copy.
pub const Codec = provider_name.Codec;

pub fn codecFamily(codec: Codec) Family {
    return switch (codec) {
        .@"openai-responses/1", .@"openai-responses/2", .@"openai-responses/3" => .responses,
        .@"anthropic-messages/1" => .messages,
    };
}

/// One wire format this server speaks. `path` is appended to the base URL;
/// null means the family's default path.
pub const Endpoint = struct {
    family: Family,
    dialect: Codec,
    path: ?[]const u8 = null,
    web_search: bool,
};

/// Which models an assignment covers. `native` is the catalog's maker-native
/// family matching the assignment's family.
pub const Match = union(enum) {
    all,
    native,
    ids: []const []const u8,
};

pub const Assignment = struct {
    models: Match,
    family: Family,
};

// ---------------------------------------------------------------- credentials

/// Exactly one credential per connection; its fields belong to its kind.
pub const Credential = union(enum) {
    /// A sign-in through the issuer's authorization-code flow. `audience` is
    /// the only address the token may be sent to.
    oauth: OAuth,
    /// OpenAI's device-code protocol, a named method. `audience` is the only
    /// address the token may be sent to.
    @"openai-device": Device,
    /// An API key the host reads from one source and places in one header.
    key: Key,

    /// The address a sign-in's token may be sent to, or null for a key.
    pub fn audience(self: Credential) ?[]const u8 {
        return switch (self) {
            .oauth => |oauth| oauth.audience,
            .@"openai-device" => |device| device.audience,
            .key => null,
        };
    }
};

pub const OAuth = struct {
    authorize_url: []const u8,
    token_url: []const u8,
    client_id: ClientId,
    scopes: []const u8,
    required_scope: []const u8,
    audience: []const u8,
    link: []const LinkField,

    pub const ClientId = union(enum) {
        fixed: []const u8,
        /// The client the issuer names for a first sign-in; the issued id is
        /// saved with the sign-in and used from then on.
        issued_at_sign_in: []const u8,
    };

    pub const LinkField = struct {
        name: []const u8,
        from: LinkSource,
    };

    pub const LinkSource = union(enum) {
        literal: []const u8,
        host_id,
    };
};

pub const Device = struct {
    client_id: []const u8,
    audience: []const u8,
};

pub const Key = struct {
    source: Source,
    placement: Placement,

    pub const Source = union(enum) {
        /// Owner-only file written by `connect`; the key bytes are never in
        /// the settings document.
        saved,
        file: []const u8,
        env: []const u8,
        /// Run by the host; its stdout is the key.
        command: []const u8,
    };

    pub const Placement = enum {
        bearer,
        @"x-api-key",
    };
};

/// A header the connection sends on every request, from a token claim or a
/// literal.
pub const Header = struct {
    name: []const u8,
    from: Source,

    pub const Source = union(enum) {
        claim: []const u8,
        literal: []const u8,
    };
};

/// A status and body that the issuer or server uses to mean something.
pub const RefusalRule = struct {
    status: u16,
    body_contains: []const u8,
    means: Means,

    pub const Means = enum {
        sign_in_required,
        key_rejected,
        refused_for_access,
    };
};

// ---------------------------------------------------------------- models and connection

pub const Models = struct {
    list: List,
    /// Glob patterns (`*` matches any run of bytes). Null: the whole list.
    allow: ?[]const []const u8,

    pub const List = enum {
        catalog,
        openai,
        chatgpt_plan,
        anthropic,
    };
};

/// A connection as the settings document describes it. Values from `parse`
/// are validated; a hand-built value must pass `validate` before `resolve`.
pub const Connection = struct {
    name: Name,
    label: []const u8,
    base_url: []const u8,
    credential: Credential,
    headers: []const Header,
    refusals: []const RefusalRule,
    formats: []const Endpoint,
    assign: []const Assignment,
    models: Models,

    pub fn endpointFor(self: *const Connection, family: Family) ?Endpoint {
        for (self.formats) |endpoint| {
            if (endpoint.family == family) return endpoint;
        }
        return null;
    }
};

/// The first reason a document or a connection is refused, and the field
/// that carries it.
pub const Refusal = struct {
    reason: Reason,
    field: []const u8,

    pub const Reason = enum {
        too_large,
        malformed_json,
        duplicate_key,
        unknown_field,
        missing_field,
        wrong_type,
        unknown_value,
        invalid_name,
        invalid_label,
        invalid_text,
        invalid_pattern,
        invalid_value,
        invalid_url,
        invalid_path,
        token_audience_mismatch,
        no_format,
        duplicate_format,
        dialect_family_mismatch,
        doubled_path_segment,
        assignment_without_format,
        reserved_header,
        duplicate_header,
        claim_without_sign_in,
        scope_not_granted,
    };
};

/// Whether the host itself sets a header of this name. The owner is the
/// shell's `provider.hostField`, which a functional core cannot import, so the
/// caller passes it in; a connection may not set any header it names.
pub const HostField = *const fn (name: []const u8) bool;

/// Checks what no single field can: the audience of a sign-in, the formats
/// (one per family, each with its dialect), the request path that would
/// double `/v1`, assignments that name a family the connection does not speak,
/// and the headers. Null means valid.
pub fn validate(c: *const Connection, host_field: HostField) ?Refusal {
    if (!validUrl(c.base_url)) return refusal(.invalid_url, "base_url");
    const base = std.mem.trimEnd(u8, c.base_url, "/");
    switch (c.credential) {
        .oauth => |oauth| {
            if (!validUrl(oauth.authorize_url)) return refusal(.invalid_url, "authorize_url");
            if (!validUrl(oauth.token_url)) return refusal(.invalid_url, "token_url");
        },
        .@"openai-device", .key => {},
    }
    switch (c.credential) {
        .oauth => |oauth| if (!scopeListed(oauth.scopes, oauth.required_scope)) return refusal(.scope_not_granted, "required_scope"),
        .@"openai-device", .key => {},
    }
    if (c.credential.audience()) |audience| {
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, audience, "/"), base)) return refusal(.token_audience_mismatch, "audience");
    }
    if (c.formats.len == 0) return refusal(.no_format, "formats");
    for (c.formats, 0..) |endpoint, index| {
        if (codecFamily(endpoint.dialect) != endpoint.family) return refusal(.dialect_family_mismatch, "dialect");
        for (c.formats[0..index]) |earlier| {
            if (earlier.family == endpoint.family) return refusal(.duplicate_format, "formats");
        }
        const path = endpoint.path orelse endpoint.family.defaultPath();
        if (endpoint.path) |text| if (!validPath(text)) return refusal(.invalid_path, "path");
        if (std.mem.endsWith(u8, base, "/v1") and (std.mem.eql(u8, path, "/v1") or std.mem.startsWith(u8, path, "/v1/"))) {
            return refusal(.doubled_path_segment, "path");
        }
        var joined: [endpoint_value.max_endpoint_bytes]u8 = undefined;
        _ = joinUnder(&joined, c.base_url, path) catch return refusal(.invalid_url, "base_url");
    }
    for (c.assign) |assignment| {
        if (c.endpointFor(assignment.family) == null) return refusal(.assignment_without_format, "assign");
    }
    const placed = credentialHeader(c.credential);
    for (c.headers, 0..) |header, index| {
        if (header.from == .claim and c.credential.audience() == null) return refusal(.claim_without_sign_in, "headers");
        if (host_field(header.name)) return refusal(.reserved_header, "headers");
        if (placed) |name| if (std.mem.eql(u8, header.name, name)) return refusal(.reserved_header, "headers");
        for (c.headers[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, header.name)) return refusal(.duplicate_header, "headers");
        }
    }
    return null;
}

/// Whether `required` is one of the space-separated scopes, as a whole word.
fn scopeListed(scopes: []const u8, required: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, scopes, ' ');
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, required)) return true;
    }
    return false;
}

/// The header a key credential places its secret in, which a connection may
/// not also set. A sign-in's bearer header is host-owned (`host_field`).
fn credentialHeader(credential: Credential) ?[]const u8 {
    return switch (credential) {
        .key => |key| switch (key.placement) {
            .bearer => "authorization",
            .@"x-api-key" => "x-api-key",
        },
        .oauth, .@"openai-device" => null,
    };
}

fn refusal(reason: Refusal.Reason, field: []const u8) Refusal {
    return .{ .reason = reason, .field = field };
}

/// The one URL rule for every URL field a connection names (base, sign-in
/// URLs): the endpoint owner's rule, and no query.
fn validUrl(text: []const u8) bool {
    if (std.mem.indexOfScalar(u8, text, '?') != null) return false;
    endpoint_value.validateEndpointUrl(text) catch return false;
    return true;
}

fn validPath(text: []const u8) bool {
    if (text.len == 0 or text[0] != '/') return false;
    for (text) |byte| {
        if (byte <= 0x20 or byte > 0x7e or byte == '?' or byte == '#') return false;
    }
    return true;
}

// ---------------------------------------------------------------- resolution

/// What the catalog knows about a model: its id, and the family its maker's
/// own API speaks (null when the catalog does not know).
pub const ModelFacts = struct {
    id: []const u8,
    native_family: ?Family,
};

pub const Resolved = struct {
    family: Family,
    codec: Codec,
    url: []const u8,
};

/// The format and URL that serve `model` on `c`, for a new binding. The first
/// assignment that covers the model wins; else the model's native family
/// when this connection speaks it; else the only family spoken; else the
/// person must add a rule. `buffer` holds the returned URL.
pub fn resolve(c: *const Connection, model: ModelFacts, buffer: []u8) error{ AmbiguousFormat, NoSpaceLeft, InvalidBaseUrl }!Resolved {
    const endpoint = choose(c, model) orelse return error.AmbiguousFormat;
    return .{
        .family = endpoint.family,
        .codec = endpoint.dialect,
        .url = try joinUnder(buffer, c.base_url, endpoint.path orelse endpoint.family.defaultPath()),
    };
}

fn choose(c: *const Connection, model: ModelFacts) ?Endpoint {
    for (c.assign) |assignment| {
        if (covers(assignment.models, model, assignment.family)) return c.endpointFor(assignment.family);
    }
    if (model.native_family) |native| {
        if (c.endpointFor(native)) |endpoint| return endpoint;
    }
    if (c.formats.len == 1) return c.formats[0];
    return null;
}

fn covers(models: Match, model: ModelFacts, family: Family) bool {
    return switch (models) {
        .all => true,
        .native => model.native_family == family,
        .ids => |patterns| for (patterns) |pattern| {
            if (globMatch(pattern, model.id)) break true;
        } else false,
    };
}

/// The request URL at `path` under `base`, through the endpoint owner's join
/// and its rules; the URL is written into `buffer`.
fn joinUnder(buffer: []u8, base: []const u8, path: []const u8) error{ NoSpaceLeft, InvalidBaseUrl }![]const u8 {
    var fixed: std.heap.FixedBufferAllocator = .init(buffer);
    return endpoint_value.endpointUnder(fixed.allocator(), base, path) catch |err| switch (err) {
        error.OutOfMemory => error.NoSpaceLeft,
        error.InvalidBaseUrl => error.InvalidBaseUrl,
    };
}

/// Whether the models list allows `id`; a connection without an allow list
/// allows every model.
pub fn allows(c: *const Connection, id: []const u8) bool {
    const patterns = c.models.allow orelse return true;
    for (patterns) |pattern| {
        if (globMatch(pattern, id)) return true;
    }
    return false;
}

/// Glob match where `*` matches any run of bytes, including none.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var resume_at: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            resume_at = t;
        } else if (p < pattern.len and pattern[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (star) |at| {
            p = at + 1;
            resume_at += 1;
            t = resume_at;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

// ---------------------------------------------------------------- parsing

pub const Outcome = union(enum) {
    ok: Connection,
    refused: Refusal,
};

/// Parses one connection document. Strings and lists are allocated in
/// `arena`, and the returned value borrows from it. Every field is required
/// except a path and an allow list: a document is the whole truth, with
/// nothing defaulted.
pub fn parse(arena: std.mem.Allocator, text: []const u8, host_field: HostField) error{OutOfMemory}!Outcome {
    var parser: Parser = .{ .arena = arena, .refusal = undefined };
    const connection = parser.connection(text) catch |err| switch (err) {
        error.Refused => return .{ .refused = parser.refusal },
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (validate(&connection, host_field)) |found| return .{ .refused = found };
    return .{ .ok = connection };
}

const Parser = struct {
    arena: std.mem.Allocator,
    refusal: Refusal,

    const Error = error{ Refused, OutOfMemory };

    fn refuse(self: *Parser, reason: Refusal.Reason, field: []const u8) Error {
        self.refusal = .{ .reason = reason, .field = field };
        return error.Refused;
    }

    fn connection(self: *Parser, text: []const u8) Error!Connection {
        if (text.len > max_document_bytes) return self.refuse(.too_large, "");
        // The JSON owner refuses a repeated key, the same rule host_settings applies.
        const root = std.json.parseFromSliceLeaky(std.json.Value, self.arena, text, .{ .duplicate_field_behavior = .@"error" }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DuplicateField => return self.refuse(.duplicate_key, ""),
            else => return self.refuse(.malformed_json, ""),
        };
        const object = try self.objectOf(root, "");
        try self.only(object, &.{ "name", "label", "base_url", "credential", "headers", "refusals", "formats", "assign", "models" });
        return .{
            .name = try self.connectionName(try self.required(object, "name")),
            .label = try self.label(try self.required(object, "label")),
            .base_url = try self.plain(try self.required(object, "base_url"), "base_url"),
            .credential = try self.credential(try self.required(object, "credential")),
            .headers = try self.listOf(Header, try self.required(object, "headers"), "headers", header),
            .refusals = try self.listOf(RefusalRule, try self.required(object, "refusals"), "refusals", refusalRule),
            .formats = try self.listOf(Endpoint, try self.required(object, "formats"), "formats", endpoint),
            .assign = try self.listOf(Assignment, try self.required(object, "assign"), "assign", assignment),
            .models = try self.models(try self.required(object, "models")),
        };
    }

    fn objectOf(self: *Parser, value: std.json.Value, field: []const u8) Error!std.json.ObjectMap {
        return switch (value) {
            .object => |map| map,
            else => self.refuse(.wrong_type, field),
        };
    }

    fn only(self: *Parser, map: std.json.ObjectMap, comptime allowed: []const []const u8) Error!void {
        for (map.keys()) |key| {
            for (allowed) |name| {
                if (std.mem.eql(u8, key, name)) break;
            } else return self.refuse(.unknown_field, key);
        }
    }

    fn required(self: *Parser, map: std.json.ObjectMap, field: []const u8) Error!std.json.Value {
        return map.get(field) orelse return self.refuse(.missing_field, field);
    }

    fn stringOf(self: *Parser, value: std.json.Value, field: []const u8) Error![]const u8 {
        return switch (value) {
            .string => |string| string,
            else => self.refuse(.wrong_type, field),
        };
    }

    /// Printable ASCII, not empty.
    fn plain(self: *Parser, value: std.json.Value, field: []const u8) Error![]const u8 {
        const string = try self.stringOf(value, field);
        if (string.len == 0) return self.refuse(.invalid_text, field);
        for (string) |byte| {
            if (byte < 0x20 or byte > 0x7e) return self.refuse(.invalid_text, field);
        }
        return string;
    }

    /// A non-empty identifier built only from `accept`.
    fn identifier(self: *Parser, value: std.json.Value, field: []const u8, comptime accept: []const u8) Error![]const u8 {
        const string = try self.stringOf(value, field);
        if (string.len == 0 or string.len > max_identifier_bytes) return self.refuse(.invalid_text, field);
        for (string) |byte| {
            if (std.mem.indexOfScalar(u8, accept, byte) == null) return self.refuse(.invalid_text, field);
        }
        return string;
    }

    fn boolean(self: *Parser, value: std.json.Value, field: []const u8) Error!bool {
        return switch (value) {
            .bool => |flag| flag,
            else => self.refuse(.wrong_type, field),
        };
    }

    fn listOf(self: *Parser, comptime T: type, value: std.json.Value, field: []const u8, comptime each: fn (*Parser, std.json.Value) Error!T) Error![]const T {
        const items = switch (value) {
            .array => |array| array.items,
            else => return self.refuse(.wrong_type, field),
        };
        const out = try self.arena.alloc(T, items.len);
        for (items, out) |item, *slot| slot.* = try each(self, item);
        return out;
    }

    fn connectionName(self: *Parser, value: std.json.Value) Error!Name {
        return Name.parse(try self.stringOf(value, "name")) orelse return self.refuse(.invalid_name, "name");
    }

    fn label(self: *Parser, value: std.json.Value) Error![]const u8 {
        const string = try self.stringOf(value, "label");
        if (string.len == 0 or string.len > max_label_bytes or !std.unicode.utf8ValidateSlice(string)) {
            return self.refuse(.invalid_label, "label");
        }
        for (string) |byte| {
            if (byte < 0x20 or byte == 0x7f) return self.refuse(.invalid_label, "label");
        }
        return string;
    }

    fn familyOf(self: *Parser, value: std.json.Value) Error!Family {
        return std.meta.stringToEnum(Family, try self.stringOf(value, "family")) orelse return self.refuse(.unknown_value, "family");
    }

    fn pattern(self: *Parser, value: std.json.Value) Error![]const u8 {
        const string = try self.stringOf(value, "pattern");
        if (string.len == 0) return self.refuse(.invalid_pattern, "pattern");
        return string;
    }

    fn credential(self: *Parser, value: std.json.Value) Error!Credential {
        const map = try self.objectOf(value, "credential");
        const kind_text = try self.stringOf(try self.required(map, "kind"), "kind");
        const kind = std.meta.stringToEnum(CredentialKind, kind_text) orelse return self.refuse(.unknown_value, "kind");
        switch (kind) {
            .oauth => {
                try self.only(map, &.{ "kind", "authorize_url", "token_url", "client_id", "scopes", "required_scope", "audience", "link" });
                return .{ .oauth = .{
                    .authorize_url = try self.plain(try self.required(map, "authorize_url"), "authorize_url"),
                    .token_url = try self.plain(try self.required(map, "token_url"), "token_url"),
                    .client_id = try self.clientId(try self.required(map, "client_id")),
                    .scopes = try self.plain(try self.required(map, "scopes"), "scopes"),
                    .required_scope = try self.plain(try self.required(map, "required_scope"), "required_scope"),
                    .audience = try self.plain(try self.required(map, "audience"), "audience"),
                    .link = try self.listOf(OAuth.LinkField, try self.required(map, "link"), "link", linkField),
                } };
            },
            .@"openai-device" => {
                try self.only(map, &.{ "kind", "client_id", "audience" });
                return .{ .@"openai-device" = .{
                    .client_id = try self.plain(try self.required(map, "client_id"), "client_id"),
                    .audience = try self.plain(try self.required(map, "audience"), "audience"),
                } };
            },
            .key => {
                try self.only(map, &.{ "kind", "source", "placement" });
                const placement_text = try self.stringOf(try self.required(map, "placement"), "placement");
                const placement = std.meta.stringToEnum(Key.Placement, placement_text) orelse return self.refuse(.unknown_value, "placement");
                return .{ .key = .{
                    .source = try self.keySource(try self.required(map, "source")),
                    .placement = placement,
                } };
            },
        }
    }

    fn clientId(self: *Parser, value: std.json.Value) Error!OAuth.ClientId {
        switch (value) {
            .string => return .{ .fixed = try self.plain(value, "client_id") },
            .object => |map| {
                try self.only(map, &.{"issued_at_sign_in"});
                return .{ .issued_at_sign_in = try self.plain(try self.required(map, "issued_at_sign_in"), "client_id") };
            },
            else => return self.refuse(.wrong_type, "client_id"),
        }
    }

    fn linkField(self: *Parser, value: std.json.Value) Error!OAuth.LinkField {
        const map = try self.objectOf(value, "link");
        try self.only(map, &.{ "name", "from" });
        const name = try self.identifier(try self.required(map, "name"), "name", "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-");
        const from_map = try self.objectOf(try self.required(map, "from"), "from");
        const kind_text = try self.stringOf(try self.required(from_map, "kind"), "kind");
        const from: OAuth.LinkSource = switch (std.meta.stringToEnum(enum { literal, host_id }, kind_text) orelse return self.refuse(.unknown_value, "kind")) {
            .literal => blk: {
                try self.only(from_map, &.{ "kind", "value" });
                break :blk .{ .literal = try self.plain(try self.required(from_map, "value"), "value") };
            },
            .host_id => blk: {
                try self.only(from_map, &.{"kind"});
                break :blk .host_id;
            },
        };
        return .{ .name = name, .from = from };
    }

    fn keySource(self: *Parser, value: std.json.Value) Error!Key.Source {
        const map = try self.objectOf(value, "source");
        const kind_text = try self.stringOf(try self.required(map, "kind"), "kind");
        switch (std.meta.stringToEnum(enum { saved, file, env, command }, kind_text) orelse return self.refuse(.unknown_value, "kind")) {
            .saved => {
                try self.only(map, &.{"kind"});
                return .saved;
            },
            .file => {
                try self.only(map, &.{ "kind", "path" });
                return .{ .file = try self.plain(try self.required(map, "path"), "path") };
            },
            .env => {
                try self.only(map, &.{ "kind", "name" });
                return .{ .env = try self.plain(try self.required(map, "name"), "name") };
            },
            .command => {
                try self.only(map, &.{ "kind", "command" });
                return .{ .command = try self.plain(try self.required(map, "command"), "command") };
            },
        }
    }

    fn header(self: *Parser, value: std.json.Value) Error!Header {
        const map = try self.objectOf(value, "headers");
        try self.only(map, &.{ "name", "from" });
        const name = try self.identifier(try self.required(map, "name"), "name", "abcdefghijklmnopqrstuvwxyz0123456789-");
        const from_map = try self.objectOf(try self.required(map, "from"), "from");
        const kind_text = try self.stringOf(try self.required(from_map, "kind"), "kind");
        const from: Header.Source = switch (std.meta.stringToEnum(enum { claim, literal }, kind_text) orelse return self.refuse(.unknown_value, "kind")) {
            .claim => blk: {
                try self.only(from_map, &.{ "kind", "name" });
                break :blk .{ .claim = try self.identifier(try self.required(from_map, "name"), "name", "abcdefghijklmnopqrstuvwxyz0123456789_") };
            },
            .literal => blk: {
                try self.only(from_map, &.{ "kind", "value" });
                break :blk .{ .literal = try self.plain(try self.required(from_map, "value"), "value") };
            },
        };
        return .{ .name = name, .from = from };
    }

    fn refusalRule(self: *Parser, value: std.json.Value) Error!RefusalRule {
        const map = try self.objectOf(value, "refusals");
        try self.only(map, &.{ "status", "body_contains", "means" });
        const status: u16 = switch (try self.required(map, "status")) {
            .integer => |number| if (number >= 400 and number <= 599) @intCast(number) else return self.refuse(.invalid_value, "status"),
            else => return self.refuse(.wrong_type, "status"),
        };
        const body = try self.plain(try self.required(map, "body_contains"), "body_contains");
        if (body.len > max_refusal_body_bytes) return self.refuse(.invalid_text, "body_contains");
        const means_text = try self.stringOf(try self.required(map, "means"), "means");
        const means = std.meta.stringToEnum(RefusalRule.Means, means_text) orelse return self.refuse(.unknown_value, "means");
        return .{ .status = status, .body_contains = body, .means = means };
    }

    fn endpoint(self: *Parser, value: std.json.Value) Error!Endpoint {
        const map = try self.objectOf(value, "formats");
        try self.only(map, &.{ "family", "dialect", "path", "web_search" });
        const family = try self.familyOf(try self.required(map, "family"));
        const dialect_text = try self.stringOf(try self.required(map, "dialect"), "dialect");
        const dialect = std.meta.stringToEnum(Codec, dialect_text) orelse return self.refuse(.unknown_value, "dialect");
        const path: ?[]const u8 = if (map.get("path")) |path_value| try self.plain(path_value, "path") else null;
        return .{
            .family = family,
            .dialect = dialect,
            .path = path,
            .web_search = try self.boolean(try self.required(map, "web_search"), "web_search"),
        };
    }

    fn assignment(self: *Parser, value: std.json.Value) Error!Assignment {
        const map = try self.objectOf(value, "assign");
        try self.only(map, &.{ "models", "family" });
        return .{
            .models = try self.match(try self.required(map, "models")),
            .family = try self.familyOf(try self.required(map, "family")),
        };
    }

    fn match(self: *Parser, value: std.json.Value) Error!Match {
        switch (value) {
            .string => |string| {
                if (std.mem.eql(u8, string, "all")) return .all;
                if (std.mem.eql(u8, string, "native")) return .native;
                return self.refuse(.unknown_value, "models");
            },
            .array => return .{ .ids = try self.listOf([]const u8, value, "models", pattern) },
            else => return self.refuse(.wrong_type, "models"),
        }
    }

    fn models(self: *Parser, value: std.json.Value) Error!Models {
        const map = try self.objectOf(value, "models");
        try self.only(map, &.{ "list", "allow" });
        const list_text = try self.stringOf(try self.required(map, "list"), "list");
        const list = std.meta.stringToEnum(Models.List, list_text) orelse return self.refuse(.unknown_value, "list");
        const allow: ?[]const []const u8 = if (map.get("allow")) |allow_value| try self.listOf([]const u8, allow_value, "allow", pattern) else null;
        return .{ .list = list, .allow = allow };
    }
};

const CredentialKind = enum { oauth, @"openai-device", key };

// ---------------------------------------------------------------- tests

/// The core's own tests name no host-owned header; the owner's probes, which
/// use `provider.hostField`, live in src/testing/connection_owners.zig.
fn noHostFields(name: []const u8) bool {
    _ = name;
    return false;
}

fn refusedBy(outcome: Outcome) ?Refusal {
    return switch (outcome) {
        .refused => |found| found,
        .ok => null,
    };
}

fn testOk(arena: std.mem.Allocator, text: []const u8) !Connection {
    return switch (try parse(arena, text, noHostFields)) {
        .ok => |connection| connection,
        .refused => error.UnexpectedRefusal,
    };
}

fn oauthOf(c: Connection) OAuth {
    return switch (c.credential) {
        .oauth => |oauth| oauth,
        else => unreachable,
    };
}

fn deviceOf(c: Connection) Device {
    return switch (c.credential) {
        .@"openai-device" => |device| device,
        else => unreachable,
    };
}

fn keyOf(c: Connection) Key {
    return switch (c.credential) {
        .key => |key| key,
        else => unreachable,
    };
}

fn issuedId(id: OAuth.ClientId) []const u8 {
    return switch (id) {
        .issued_at_sign_in => |text| text,
        else => unreachable,
    };
}

fn literalOf(source: OAuth.LinkSource) []const u8 {
    return switch (source) {
        .literal => |text| text,
        else => unreachable,
    };
}

fn claimOf(source: Header.Source) []const u8 {
    return switch (source) {
        .claim => |name| name,
        else => unreachable,
    };
}

const base_document =
    \\{
    \\  "name": "gateway",
    \\  "label": "Gateway",
    \\  "base_url": "https://gateway.example/v1",
    \\  "credential": {"kind": "key", "source": {"kind": "saved"}, "placement": "bearer"},
    \\  "headers": [],
    \\  "refusals": [],
    \\  "formats": [{"family": "responses", "dialect": "openai-responses/3", "web_search": false}],
    \\  "assign": [],
    \\  "models": {"list": "openai"}
    \\}
;

test "the base document parses to the values it spells" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const connection = try testOk(arena.allocator(), base_document);
    try std.testing.expectEqualStrings("gateway", connection.name.slice());
    try std.testing.expectEqualStrings("Gateway", connection.label);
    try std.testing.expectEqualStrings("https://gateway.example/v1", connection.base_url);
    try std.testing.expectEqual(Models.List.openai, connection.models.list);
    try std.testing.expect(connection.models.allow == null);
    try std.testing.expectEqual(Key.Placement.bearer, keyOf(connection).placement);
    try std.testing.expect(std.meta.activeTag(keyOf(connection).source) == .saved);
    try std.testing.expectEqual(Codec.@"openai-responses/3", connection.formats[0].dialect);
    try std.testing.expect(connection.formats[0].path == null);
}

test "parse refuses each malformed field with its reason and field" {
    const cases = [_]struct { from: []const u8, to: []const u8, reason: Refusal.Reason, field: []const u8 }{
        .{ .from = "\"name\": \"gateway\"", .to = "\"name\": \"Gateway\"", .reason = .invalid_name, .field = "name" },
        .{ .from = "\"name\": \"gateway\"", .to = "\"name\": \"\"", .reason = .invalid_name, .field = "name" },
        .{ .from = "\"name\": \"gateway\"", .to = "\"name\": \"gateway-name-too-long\"", .reason = .invalid_name, .field = "name" },
        .{ .from = "\"label\": \"Gateway\"", .to = "\"label\": \"\"", .reason = .invalid_label, .field = "label" },
        .{ .from = "\"label\": \"Gateway\"", .to = "\"label\": \"a\\u0007b\"", .reason = .invalid_label, .field = "label" },
        .{ .from = "\"label\": \"Gateway\"", .to = "\"label\": \"ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGHIJKLMNOP\"", .reason = .invalid_label, .field = "label" },
        .{ .from = "\"base_url\": \"https://gateway.example/v1\",", .to = "", .reason = .missing_field, .field = "base_url" },
        .{ .from = "\"base_url\": \"https://gateway.example/v1\"", .to = "\"base_url\": 7", .reason = .wrong_type, .field = "base_url" },
        .{ .from = "\"headers\": [],", .to = "\"headers\": [], \"extra\": 1,", .reason = .unknown_field, .field = "extra" },
        .{ .from = "\"assign\": [],", .to = "\"assign\": [], \"assign\": [],", .reason = .duplicate_key, .field = "" },
        .{ .from = "\"models\": {\"list\": \"openai\"}", .to = "\"models\": {", .reason = .malformed_json, .field = "" },
        .{ .from = "\"placement\": \"bearer\"", .to = "\"placement\": \"bearer\", \"client_id\": \"x\"", .reason = .unknown_field, .field = "client_id" },
        .{ .from = "\"source\": {\"kind\": \"saved\"}", .to = "\"source\": {\"kind\": \"saved\", \"path\": \"/x\"}", .reason = .unknown_field, .field = "path" },
        .{ .from = "\"kind\": \"key\"", .to = "\"kind\": \"none\"", .reason = .unknown_value, .field = "kind" },
        .{ .from = "\"placement\": \"bearer\"", .to = "\"placement\": \"basic\"", .reason = .unknown_value, .field = "placement" },
        .{ .from = "\"family\": \"responses\"", .to = "\"family\": \"chat\"", .reason = .unknown_value, .field = "family" },
        .{ .from = "\"openai-responses/3\"", .to = "\"openai-responses/9\"", .reason = .unknown_value, .field = "dialect" },
        .{ .from = "\"list\": \"openai\"", .to = "\"list\": \"gateway\"", .reason = .unknown_value, .field = "list" },
        .{ .from = "\"models\": {\"list\": \"openai\"}", .to = "\"models\": {\"list\": \"openai\", \"allow\": [\"\"]}", .reason = .invalid_pattern, .field = "pattern" },
        .{ .from = "\"refusals\": []", .to = "\"refusals\": [{\"status\": 200, \"body_contains\": \"x\", \"means\": \"key_rejected\"}]", .reason = .invalid_value, .field = "status" },
        .{ .from = "\"refusals\": []", .to = "\"refusals\": [{\"status\": 403, \"body_contains\": \"x\", \"means\": \"nope\"}]", .reason = .unknown_value, .field = "means" },
        .{ .from = "\"headers\": []", .to = "\"headers\": [{\"name\": \"X-Team\", \"from\": {\"kind\": \"literal\", \"value\": \"a\"}}]", .reason = .invalid_text, .field = "name" },
        .{ .from = "\"headers\": []", .to = "\"headers\": [{\"name\": \"x-team\", \"from\": {\"kind\": \"literal\", \"value\": \"\"}}]", .reason = .invalid_text, .field = "value" },
        .{ .from = "\"headers\": []", .to = "\"headers\": [{\"name\": \"x-team\", \"from\": {\"kind\": \"env\"}}]", .reason = .unknown_value, .field = "kind" },
        .{ .from = "\"assign\": []", .to = "\"assign\": [{\"models\": \"everything\", \"family\": \"responses\"}]", .reason = .unknown_value, .field = "models" },
        .{ .from = "\"assign\": []", .to = "\"assign\": [{\"models\": [\"claude-*\"], \"family\": \"messages\", \"x\": 1}]", .reason = .unknown_field, .field = "x" },
        .{ .from = "\"assign\": []", .to = "\"assign\": [", .reason = .malformed_json, .field = "" },
    };
    for (cases) |case| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const text = try std.mem.replaceOwned(u8, arena.allocator(), base_document, case.from, case.to);
        const found = refusedBy(try parse(arena.allocator(), text, noHostFields)) orelse {
            std.debug.print("accepted but refused expected {s}: {s}\n", .{ @tagName(case.reason), case.from });
            return error.TestExpectedRefusal;
        };
        try std.testing.expectEqual(case.reason, found.reason);
        try std.testing.expectEqualStrings(case.field, found.field);
    }
}

test "parse refuses a document that is not one object, or is too large" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqual(Refusal.Reason.wrong_type, refusedBy(try parse(allocator, "[]", noHostFields)).?.reason);
    const large = try allocator.alloc(u8, max_document_bytes + 1);
    @memset(large, ' ');
    try std.testing.expectEqual(Refusal.Reason.too_large, refusedBy(try parse(allocator, large, noHostFields)).?.reason);
}

test "parse accepts the names and labels at their bounds and refuses one past each" {
    try std.testing.expect(Name.parse("a") != null);
    try std.testing.expect(Name.parse("a-b-9") != null);
    try std.testing.expect(Name.parse("aaaaaaaaaaaaaaaa") != null);
    try std.testing.expect(Name.parse("aaaaaaaaaaaaaaaaa") == null);
    try std.testing.expect(Name.parse("") == null);
    try std.testing.expect(Name.parse("9a") == null);
    try std.testing.expect(Name.parse("A") == null);
    try std.testing.expect(Name.parse("a_b") == null);
    try std.testing.expect(Name.parse("a b") == null);
    for (0..256) |value| {
        const byte: u8 = @intCast(value);
        const allowed = (byte >= 'a' and byte <= 'z') or (byte >= '0' and byte <= '9') or byte == '-';
        try std.testing.expectEqual(allowed, Name.parse(&.{ 'a', byte }) != null);
    }
}

test "parse keeps a credential's fields to its own kind" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const device = try std.mem.replaceOwned(u8, allocator, base_document,
        \\"credential": {"kind": "key", "source": {"kind": "saved"}, "placement": "bearer"}
    ,
        \\"credential": {"kind": "openai-device", "client_id": "app_x", "audience": "https://gateway.example/v1", "source": {"kind": "saved"}}
    );
    try std.testing.expectEqual(Refusal.Reason.unknown_field, refusedBy(try parse(allocator, device, noHostFields)).?.reason);
}

test "validate refuses a sign-in token sent anywhere but its audience" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    const oauth: Credential = .{ .oauth = .{
        .authorize_url = "https://auth.example/authorize",
        .token_url = "https://auth.example/token",
        .client_id = .{ .fixed = "client" },
        .scopes = "openid",
        .required_scope = "openid",
        .audience = "https://api.openai.com/v1",
        .link = &.{},
    } };
    connection.credential = oauth;
    try std.testing.expectEqual(Refusal.Reason.token_audience_mismatch, validate(&connection, noHostFields).?.reason);

    connection.credential = .{ .@"openai-device" = .{ .client_id = "app_x", .audience = "https://chatgpt.com/backend-api/codex" } };
    try std.testing.expectEqual(Refusal.Reason.token_audience_mismatch, validate(&connection, noHostFields).?.reason);

    connection.base_url = "https://chatgpt.com/backend-api/codex/";
    try std.testing.expect(validate(&connection, noHostFields) == null);

    connection.base_url = "https://gateway.example/v1";
    connection.credential = .{ .oauth = .{
        .authorize_url = "https://auth.example/authorize",
        .token_url = "https://auth.example/token",
        .client_id = .{ .issued_at_sign_in = "dynamic_agent_client" },
        .scopes = "openid",
        .required_scope = "openid",
        .audience = "https://gateway.example/v1/",
        .link = &.{},
    } };
    try std.testing.expect(validate(&connection, noHostFields) == null);
}

test "validate allows a credential only over https, never plain HTTP to loopback" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    connection.base_url = "https://gateway.example/v1";
    try std.testing.expect(validate(&connection, noHostFields) == null);
    connection.base_url = "http://127.0.0.1:9/v1";
    try std.testing.expectEqual(Refusal.Reason.invalid_url, validate(&connection, noHostFields).?.reason);
    connection.base_url = "http://gateway.example/v1";
    try std.testing.expectEqual(Refusal.Reason.invalid_url, validate(&connection, noHostFields).?.reason);
    connection.base_url = "https://gateway.example/v1?x=1";
    try std.testing.expectEqual(Refusal.Reason.invalid_url, validate(&connection, noHostFields).?.reason);
}

test "validate holds the sign-in URLs to the base URL's rule: https, no query, never plain HTTP" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    const base = "https://gateway.example/v1";
    connection.credential = .{ .oauth = .{
        .authorize_url = "https://auth.example/authorize",
        .token_url = "https://auth.example/token",
        .client_id = .{ .fixed = "client" },
        .scopes = "openid",
        .required_scope = "openid",
        .audience = base,
        .link = &.{},
    } };
    try std.testing.expect(validate(&connection, noHostFields) == null);
    const bad = [_][]const u8{
        "http://127.0.0.1:8080/token",
        "http://[::1]:8080/token",
        "http://auth.example/token",
        "https://auth.example/token?x=1",
        "https://auth.example/token#f",
        "https://user@auth.example/token",
    };
    for (bad) |text| {
        for ([_]bool{ true, false }) |authorize| {
            connection.credential = .{ .oauth = .{
                .authorize_url = if (authorize) text else "https://auth.example/authorize",
                .token_url = if (authorize) "https://auth.example/token" else text,
                .client_id = .{ .fixed = "client" },
                .scopes = "openid",
                .required_scope = "openid",
                .audience = base,
                .link = &.{},
            } };
            const found = validate(&connection, noHostFields) orelse return error.TestExpectedRefusal;
            try std.testing.expectEqual(Refusal.Reason.invalid_url, found.reason);
            try std.testing.expectEqualStrings(if (authorize) "authorize_url" else "token_url", found.field);
        }
    }
}

test "validate refuses a claim header on a credential with no token, and a required scope that is not granted" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const base = "https://gateway.example/v1";
    var connection = try testOk(arena.allocator(), base_document);
    const kinds = [_]enum { oauth, device, key }{ .oauth, .device, .key };
    const sources = [_]enum { claim, literal }{ .claim, .literal };
    for (kinds) |kind| for (sources) |source| {
        connection.credential = switch (kind) {
            .oauth => .{ .oauth = .{
                .authorize_url = "https://auth.example/authorize",
                .token_url = "https://auth.example/token",
                .client_id = .{ .fixed = "client" },
                .scopes = "openid chatgpt.tokens.use.direct",
                .required_scope = "chatgpt.tokens.use.direct",
                .audience = base,
                .link = &.{},
            } },
            .device => .{ .@"openai-device" = .{ .client_id = "app_x", .audience = base } },
            .key => .{ .key = .{ .source = .saved, .placement = .bearer } },
        };
        connection.headers = &.{.{
            .name = "x-team",
            .from = switch (source) {
                .claim => .{ .claim = "account_id" },
                .literal => .{ .literal = "a" },
            },
        }};
        // A key has no token to read a claim from; a sign-in's token is the claim's source.
        const expected: ?Refusal.Reason = if (kind == .key and source == .claim) .claim_without_sign_in else null;
        const found = validate(&connection, noHostFields);
        try std.testing.expectEqual(expected, if (found) |refused| refused.reason else null);
    };

    // Scope membership is by whole word: present, absent, and a prefix or extension of the required scope.
    const scope_cases = [_]struct { scopes: []const u8, required: []const u8, refused: bool }{
        .{ .scopes = "openid chatgpt.tokens.use.direct", .required = "chatgpt.tokens.use.direct", .refused = false },
        .{ .scopes = "chatgpt.tokens.use.direct openid", .required = "chatgpt.tokens.use.direct", .refused = false },
        .{ .scopes = "openid", .required = "chatgpt.tokens.use.direct", .refused = true },
        .{ .scopes = "openid chatgpt.tokens.use.direct.extra", .required = "chatgpt.tokens.use.direct", .refused = true },
        .{ .scopes = "openid chatgpt.tokens.use", .required = "chatgpt.tokens.use.direct", .refused = true },
    };
    connection.headers = &.{};
    for (scope_cases) |case| {
        connection.credential = .{ .oauth = .{
            .authorize_url = "https://auth.example/authorize",
            .token_url = "https://auth.example/token",
            .client_id = .{ .fixed = "client" },
            .scopes = case.scopes,
            .required_scope = case.required,
            .audience = base,
            .link = &.{},
        } };
        const found = validate(&connection, noHostFields);
        if (case.refused) {
            try std.testing.expectEqual(Refusal.Reason.scope_not_granted, found.?.reason);
        } else {
            try std.testing.expect(found == null);
        }
    }
}

test "validate refuses no format, two endpoints of one family, and a dialect of another family" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    const responses3: Endpoint = .{ .family = .responses, .dialect = .@"openai-responses/3", .web_search = false };
    const responses2: Endpoint = .{ .family = .responses, .dialect = .@"openai-responses/2", .web_search = false };
    const messages1: Endpoint = .{ .family = .messages, .dialect = .@"anthropic-messages/1", .web_search = false };

    connection.formats = &.{};
    try std.testing.expectEqual(Refusal.Reason.no_format, validate(&connection, noHostFields).?.reason);
    connection.formats = &.{ responses3, responses2 };
    try std.testing.expectEqual(Refusal.Reason.duplicate_format, validate(&connection, noHostFields).?.reason);
    connection.formats = &.{ responses3, messages1 };
    try std.testing.expect(validate(&connection, noHostFields) == null);
    connection.formats = &.{.{ .family = .responses, .dialect = .@"anthropic-messages/1", .web_search = false }};
    try std.testing.expectEqual(Refusal.Reason.dialect_family_mismatch, validate(&connection, noHostFields).?.reason);
}

test "validate refuses an assignment to a family the connection does not speak" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    connection.assign = &.{.{ .models = .all, .family = .messages }};
    try std.testing.expectEqual(Refusal.Reason.assignment_without_format, validate(&connection, noHostFields).?.reason);
}

test "validate refuses a path that doubles /v1 and a path that is not a path" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    const doubled: Endpoint = .{ .family = .responses, .dialect = .@"openai-responses/3", .path = "/v1/responses", .web_search = false };
    connection.formats = &.{doubled};
    try std.testing.expectEqual(Refusal.Reason.doubled_path_segment, validate(&connection, noHostFields).?.reason);

    connection.base_url = "https://gateway.example";
    try std.testing.expect(validate(&connection, noHostFields) == null);

    for ([_][]const u8{ "responses", "/x?y=1", "/x#f", "/x y" }) |path| {
        connection.formats = &.{.{ .family = .responses, .dialect = .@"openai-responses/3", .path = path, .web_search = false }};
        try std.testing.expectEqual(Refusal.Reason.invalid_path, validate(&connection, noHostFields).?.reason);
    }
}

test "validate refuses reserved and repeated headers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    connection.headers = &.{.{ .name = "authorization", .from = .{ .literal = "x" } }};
    try std.testing.expectEqual(Refusal.Reason.reserved_header, validate(&connection, noHostFields).?.reason);
    connection.headers = &.{
        .{ .name = "x-team", .from = .{ .literal = "a" } },
        .{ .name = "x-team", .from = .{ .literal = "b" } },
    };
    try std.testing.expectEqual(Refusal.Reason.duplicate_header, validate(&connection, noHostFields).?.reason);
}

test "resolve takes the first assignment that covers the model" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    connection.formats = &.{
        .{ .family = .responses, .dialect = .@"openai-responses/3", .web_search = false },
        .{ .family = .messages, .dialect = .@"anthropic-messages/1", .web_search = false },
    };
    const rule_ids = [_][]const u8{ "gpt-5.1", "claude-*" };
    connection.assign = &.{
        .{ .models = .{ .ids = &rule_ids }, .family = .messages },
        .{ .models = .all, .family = .responses },
    };
    var buffer: [256]u8 = undefined;

    // A rule beats the model's own family: gpt-5.1 is Responses by catalog but Messages here.
    const gpt = try resolve(&connection, .{ .id = "gpt-5.1", .native_family = .responses }, &buffer);
    try std.testing.expectEqual(Family.messages, gpt.family);
    // A rule matches by pattern, whatever the catalog says.
    const claude = try resolve(&connection, .{ .id = "claude-x", .native_family = null }, &buffer);
    try std.testing.expectEqual(Family.messages, claude.family);
    // The catch-all comes later, so it only takes what no earlier rule covers.
    const other = try resolve(&connection, .{ .id = "other", .native_family = .messages }, &buffer);
    try std.testing.expectEqual(Family.responses, other.family);
    try std.testing.expectEqual(Codec.@"openai-responses/3", other.codec);
}

test "resolve uses the model's own family when this connection speaks it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    connection.formats = &.{
        .{ .family = .responses, .dialect = .@"openai-responses/2", .web_search = true },
        .{ .family = .messages, .dialect = .@"anthropic-messages/1", .web_search = false },
    };
    connection.assign = &.{.{ .models = .native, .family = .messages }};
    var buffer: [256]u8 = undefined;

    const claude = try resolve(&connection, .{ .id = "claude-sonnet-4.5", .native_family = .messages }, &buffer);
    try std.testing.expectEqual(Family.messages, claude.family);
    try std.testing.expectEqualStrings("https://gateway.example/v1/messages", claude.url);
    const gpt = try resolve(&connection, .{ .id = "gpt-5.1", .native_family = .responses }, &buffer);
    try std.testing.expectEqual(Family.responses, gpt.family);
    try std.testing.expectEqual(Codec.@"openai-responses/2", gpt.codec);
}

test "resolve uses the only family a connection speaks, for any model" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    var buffer: [256]u8 = undefined;
    const resolved = try resolve(&connection, .{ .id = "unknown-model", .native_family = null }, &buffer);
    try std.testing.expectEqual(Family.responses, resolved.family);
    try std.testing.expectEqual(Codec.@"openai-responses/3", resolved.codec);
}

test "resolve refuses a model with no rule, no known family and two families spoken" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    connection.formats = &.{
        .{ .family = .responses, .dialect = .@"openai-responses/3", .web_search = false },
        .{ .family = .messages, .dialect = .@"anthropic-messages/1", .web_search = false },
    };
    var buffer: [256]u8 = undefined;
    try std.testing.expectError(error.AmbiguousFormat, resolve(&connection, .{ .id = "unknown-model", .native_family = null }, &buffer));
}

test "resolve joins the base URL and the family path with and without /v1" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    var buffer: [256]u8 = undefined;
    const model: ModelFacts = .{ .id = "gpt-5.1", .native_family = .responses };

    for ([_]struct { base: []const u8, url: []const u8 }{
        .{ .base = "https://gateway.example/v1", .url = "https://gateway.example/v1/responses" },
        .{ .base = "https://gateway.example/v1/", .url = "https://gateway.example/v1/responses" },
        .{ .base = "https://gateway.example", .url = "https://gateway.example/responses" },
        .{ .base = "https://gateway.example/openai/v1/", .url = "https://gateway.example/openai/v1/responses" },
    }) |case| {
        connection.base_url = case.base;
        const resolved = try resolve(&connection, model, &buffer);
        try std.testing.expectEqualStrings(case.url, resolved.url);
    }

    connection.base_url = "https://gateway.example";
    connection.formats = &.{.{ .family = .responses, .dialect = .@"openai-responses/3", .path = "/openai/responses", .web_search = false }};
    const overridden = try resolve(&connection, model, &buffer);
    try std.testing.expectEqualStrings("https://gateway.example/openai/responses", overridden.url);

    var small: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, resolve(&connection, model, &small));
}

test "globs match whole ids, with * for any run of bytes" {
    const cases = [_]struct { pattern: []const u8, text: []const u8, matches: bool }{
        .{ .pattern = "*", .text = "", .matches = true },
        .{ .pattern = "*", .text = "anything", .matches = true },
        .{ .pattern = "claude-*", .text = "claude-sonnet-4.5", .matches = true },
        .{ .pattern = "claude-*", .text = "claude", .matches = false },
        .{ .pattern = "gpt-5*", .text = "gpt-5.1", .matches = true },
        .{ .pattern = "gpt-5*", .text = "gpt-4", .matches = false },
        .{ .pattern = "gpt-5.1", .text = "gpt-5.1", .matches = true },
        .{ .pattern = "gpt-5.1", .text = "gpt-5.10", .matches = false },
        .{ .pattern = "a*b*c", .text = "axxbyyc", .matches = true },
        .{ .pattern = "a*b*c", .text = "axxbyy", .matches = false },
        .{ .pattern = "*-x", .text = "a-x-y", .matches = false },
        .{ .pattern = "", .text = "", .matches = true },
        .{ .pattern = "", .text = "a", .matches = false },
    };
    for (cases) |case| try std.testing.expectEqual(case.matches, globMatch(case.pattern, case.text));
}

test "allows reads the allow list, and a connection without one allows every model" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var connection = try testOk(arena.allocator(), base_document);
    try std.testing.expect(allows(&connection, "anything"));
    connection.models.allow = &.{ "gpt-5*", "claude-*" };
    try std.testing.expect(allows(&connection, "gpt-5.1"));
    try std.testing.expect(allows(&connection, "claude-opus"));
    try std.testing.expect(!allows(&connection, "mistral-large"));
}

// ---------------------------------------------------------------- the connections list

/// The most names one Host serves: every listed connection plus every
/// built-in. A listed connection under a built-in name replaces it.
pub const max_served = 16;
/// The most built-in names a Host serves beside the listed connections;
/// provider_route checks the built-in list against it.
pub const max_built_in = 3;
/// The most connections one document may list: what the served set holds
/// beside every built-in.
pub const max_list = max_served - max_built_in;

/// The connections a settings document lists, in order. Each entry keeps the
/// connection the parser read and the JSON it came from, which `write` emits
/// again; the strings borrow from `memory`. This is the one owner of what a
/// list may hold: its names, its count and what this Rui version serves.
pub const Connections = struct {
    entries: []const Entry = &.{},
    memory: ?std.heap.ArenaAllocator = null,

    pub const Entry = struct {
        value: Connection,
        document: std.json.ObjectMap,
    };

    /// The first problem with a list or one of its entries. `index` is the
    /// entry, null for the list itself; `field` is the Connection field the
    /// parser named, or empty; `reason` is the reason as text.
    pub const Failure = struct {
        index: ?usize,
        field: []const u8,
        reason: []const u8,
    };

    pub fn deinit(self: *Connections) void {
        if (self.memory) |*memory| memory.deinit();
        self.* = .{};
    }

    /// Parses a document's array of connection objects. An empty array leaves
    /// the list empty. Scratch goes in `scratch`; the kept values in a new
    /// arena that replaces this list only when every entry is valid.
    pub fn parseItems(self: *Connections, gpa: std.mem.Allocator, scratch: std.mem.Allocator, items: []const std.json.Value, host_field: HostField) error{OutOfMemory}!?Failure {
        if (items.len > max_list) return .{ .index = null, .field = "", .reason = "too many connections" };
        if (items.len == 0) {
            self.deinit();
            return null;
        }
        var memory: std.heap.ArenaAllocator = .init(gpa);
        var kept = false;
        defer if (!kept) memory.deinit();
        const retained = try memory.allocator().alloc(Entry, items.len);
        for (items, retained, 0..) |item, *slot, index| {
            if (item != .object) return .{ .index = index, .field = "", .reason = "must be an object" };
            const encoded = try std.json.Stringify.valueAlloc(scratch, item, .{});
            switch (try parse(memory.allocator(), encoded, host_field)) {
                .ok => |value| slot.* = .{ .value = value, .document = undefined },
                // The field may live in `memory`, which is freed on return; the caller owns `scratch`.
                .refused => |found| return .{ .index = index, .field = try scratch.dupe(u8, found.field), .reason = @tagName(found.reason) },
            }
            const document = std.json.parseFromSliceLeaky(std.json.Value, memory.allocator(), encoded, .{ .allocate = .alloc_always, .parse_numbers = false }) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => unreachable,
            };
            slot.document = document.object;
            if (Connections.checkNames(retained[0 .. index + 1])) |failure| return failure;
        }
        self.deinit();
        self.* = .{ .entries = retained, .memory = memory };
        kept = true;
        return null;
    }

    /// The name and count rules: a name is unique and not one a sign-in owns.
    /// Checked on each entry as it arrives, so an earlier entry is the
    /// duplicate's owner.
    pub fn checkNames(entries: []const Entry) ?Failure {
        if (entries.len > max_list) return .{ .index = null, .field = "", .reason = "too many connections" };
        for (entries, 0..) |entry, index| {
            if (reservedName(entry.value.name.slice())) return .{ .index = index, .field = "name", .reason = "reserved for the ChatGPT sign-in" };
            for (entries[0..index]) |before| {
                if (before.value.name.eql(entry.value.name)) return .{ .index = index, .field = "name", .reason = "duplicate connection name" };
            }
        }
        return null;
    }

    /// The first connection this Rui version does not serve, and the field
    /// that makes it so. It serves one Responses format, no extra headers or
    /// refusal rules, and one of: a bearer key, a ChatGPT browser sign-in
    /// (`oauth` speaking `openai-responses/3`) or a ChatGPT device sign-in
    /// (`openai-device` speaking `openai-responses/2`). A sign-in's record is
    /// its own file per name, so two names never share one.
    pub fn unserved(self: *const Connections) ?struct { name: []const u8, field: []const u8 } {
        for (self.entries) |*entry| {
            const name = entry.value.name.slice();
            if (entry.value.formats.len != 1 or entry.value.formats[0].family != .responses) return .{ .name = name, .field = "formats" };
            if (entry.value.headers.len != 0) return .{ .name = name, .field = "headers" };
            if (entry.value.refusals.len != 0) return .{ .name = name, .field = "refusals" };
            switch (entry.value.credential) {
                .key => |key| {
                    if (key.placement != .bearer) return .{ .name = name, .field = "credential" };
                    if (key.source == .command) return .{ .name = name, .field = "credential.source" };
                },
                .oauth => if (entry.value.formats[0].dialect != .@"openai-responses/3") return .{ .name = name, .field = "credential" },
                .@"openai-device" => if (entry.value.formats[0].dialect != .@"openai-responses/2") return .{ .name = name, .field = "credential" },
            }
        }
        return null;
    }

    /// The document form: the entries' JSON, in order, as one array.
    pub fn write(self: *const Connections, out: *std.Io.Writer) std.Io.Writer.Error!void {
        try out.writeByte('[');
        for (self.entries, 0..) |entry, i| {
            if (i != 0) try out.writeByte(',');
            try std.json.Stringify.value(std.json.Value{ .object = entry.document }, .{}, out);
        }
        try out.writeByte(']');
    }
};

/// Whether a built-in sign-in owns the name (`codex`, `chatgpt`): a connection may not take it.
pub fn reservedName(name: []const u8) bool {
    inline for (std.enums.values(provider_name.Provider)) |provider| {
        if (provider.facts().credential == .sign_in and std.mem.eql(u8, name, @tagName(provider))) return true;
    }
    return false;
}
