//! The Host's wire contract as an OpenAPI 3.1 document, built from
//! protocol.zig's JSON shapes: the request shapes the client writes and the
//! reply shapes the Host writes. `zig build openapi` writes it to
//! `openapi.json`; a test fails when the checked-in file differs from what
//! this emits. Generated requests with all or no optional members, in their
//! original and seeded random orders, exercise the Host's own parser. Clients in other languages are
//! generated from that file.
//!
//! A shape is a tuple of literal JSON text and `protocol.Hole`s. To turn one
//! into a schema, each hole is written as a marker string, the text is parsed
//! as JSON, and each marker becomes its hole's schema. A shape here may also
//! hold a marker type (see `Optional`, `ListOf`, `State`, `Content`) for the parts the
//! Host and client write in code rather than as one shape.
const std = @import("std");
const model_catalog = @import("model_catalog.zig");
const session_settings = @import("session_settings.zig");
const protocol = @import("protocol.zig");
const wire_request = @import("wire_request.zig");
const model_list = @import("model_list.zig");
const store = @import("store.zig");
const session_report_reply = @import("session_report_reply.zig");
const activity_reply = @import("activity_reply.zig");
const host_settings = @import("host_settings.zig");
const start_report = @import("start_report.zig");
const core_tools = @import("core_tools.zig");
const Hole = protocol.Hole;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// One route: its path, its request variants, and its reply.
const Route = struct {
    path: []const u8,
    kind: protocol.Kind,
    summary: []const u8,
    /// One object shape, or genuinely exclusive target alternatives.
    variants: []const Variant,
    reply: Reply,
    /// The reply under HTTP 409 when a retried key meets different input.
    conflict: ?Reply = null,
};

/// A request shape, kept as its two uses so `Route` stays a runtime value.
const Variant = struct {
    schema: *const fn (*Document) anyerror!Value,
    example: *const fn (*std.Io.Writer, bool) anyerror!void,
};

fn variant(comptime shape: anytype, comptime examples: anytype) Variant {
    const S = struct {
        const value = shape;
        fn schema(d: *Document) anyerror!Value {
            return d.shapeSchema(value);
        }
        fn example(out: *std.Io.Writer, optional: bool) anyerror!void {
            return writeExampleWith(out, value, examples, optional);
        }
    };
    return .{ .schema = S.schema, .example = S.example };
}

const Reply = union(enum) {
    /// A JSON reply, any one of these.
    json: *const fn (*Document) anyerror!Value,
    /// Raw content bytes (`application/octet-stream`).
    bytes,
    /// Text content (`text/plain`), as the result and Action reads send it.
    text,
    /// A described Session report (JSON), or a failed response's raw bytes.
    report,
};

fn jsonReply(comptime shapes: anytype) Reply {
    const S = struct {
        fn schema(d: *Document) anyerror!Value {
            var values: [shapes.len]Value = undefined;
            inline for (shapes, 0..) |shape, index| values[index] = try d.shapeSchema(shape);
            return d.anyOf(&values);
        }
    };
    return .{ .json = S.schema };
}

/// Every route, in the order the document lists them.
pub const routes = [_]Route{
    .{
        .path = "/v1/host-info",
        .kind = .host_info,
        .summary = "The Host's identity, capacity and provider routes. Also the readiness probe.",
        .variants = &.{variant(protocol.host_info_request, .{})},
        .reply = jsonReply(.{protocol.host_info_reply.head ++ .{Optional(protocol.host_info_reply.doublewrite)} ++ protocol.host_info_reply.tail}),
    },
    .{
        .path = "/v1/control/host-stop",
        .kind = .host_stop,
        .summary = "Stops the Host after its work drains.",
        .variants = &.{variant(protocol.host_stop_request, .{})},
        .reply = jsonReply(.{.{protocol.host_stop_ack}}),
    },
    .{
        .path = "/v1/control/host-pause",
        .kind = .host_pause,
        .summary = "Holds every new Turn while paused, or releases them. Running work continues.",
        .variants = &.{variant(protocol.host_pause_request, .{})},
        .reply = jsonReply(.{protocol.host_pause_reply}),
    },
    .{
        .path = protocol.CommandKind.configure.route(),
        .kind = .configure,
        .summary = "Creates or reconfigures a Session. Retried by its key.",
        .variants = &.{variant(protocol.configure_request.head ++ .{Configuration} ++ .{
            Optional(protocol.configure_request.reload_skills),
            Optional(protocol.configure_request.require_model),
            Optional(protocol.configure_request.preset),
        } ++ protocol.configure_request.tail, .{})},
        .reply = jsonReply(.{ protocol.configuration_reply.accepted, protocol.configuration_reply.accepted_skills, protocol.configuration_reply.rejected }),
        .conflict = jsonReply(.{protocol.configuration_reply.conflict}),
    },
    .{
        .path = protocol.CommandKind.message.route(),
        .kind = .message,
        .summary = "Sends a Message to a Session, or creates the Session when `session` is empty. Retried by its key. Each `/name` word in the text that names a skill in the recipient's catalog appends that skill to what the model reads; the text is saved as written. Only an empty `session` carries (and requires) `configuration`; `require_model` is allowed only with it. The body starts with the client environment, `X-Rui-Environment-Bytes` long, before the JSON.",
        .variants = &.{variant(protocol.message_request.head ++ .{Sender} ++ protocol.message_request.sender_handle ++ .{
            Optional(protocol.message_request.configuration ++ .{MessageConfiguration}),
        } ++ protocol.message_request.text ++ .{Content} ++ protocol.message_request.text_tail ++ .{
            Optional(protocol.message_request.require_model),
        } ++ protocol.message_request.tail, .{
            // Only creation carries configuration and require_model. Exercise
            // an addressed Message without them, and both nullable senders.
            .{ 2, "\"\"", "\"aaaaaa\"" },
            .{ 3, "{\"store\":\"/s\",\"session\":\"aaaaaa\"}", "null" },
        })},
        .reply = jsonReply(.{ protocol.message_reply.accepted, protocol.message_reply.rejected }),
        .conflict = jsonReply(.{protocol.message_reply.conflict}),
    },
    .{
        .path = protocol.CommandKind.session_stop.route(),
        .kind = .session_stop,
        .summary = "Stops a Session's current and queued work. Retried by its key.",
        .variants = &.{variant(protocol.session_stop_request, .{})},
        .reply = jsonReply(.{ protocol.session_stop_reply.accepted, protocol.session_stop_reply.rejected }),
        .conflict = jsonReply(.{protocol.session_stop_reply.conflict}),
    },
    .{
        .path = protocol.CommandKind.session_archive.route(),
        .kind = .session_archive,
        .summary = "Archives or restores a Session. Archiving stops current and queued work. Retried by its key.",
        .variants = &.{variant(protocol.session_archive_request.head ++ .{Optional(protocol.session_archive_request.archived)} ++ protocol.session_archive_request.tail, .{})},
        .reply = jsonReply(.{ protocol.session_archive_reply.accepted, protocol.session_archive_reply.rejected }),
        .conflict = jsonReply(.{protocol.session_archive_reply.conflict}),
    },
    .{
        .path = protocol.CommandKind.model_interruption.route(),
        .kind = .model_interruption,
        .summary = "Interrupts one model Operation. Retried by its key.",
        .variants = &.{variant(protocol.model_interruption_request, .{})},
        .reply = jsonReply(.{ protocol.model_interruption_reply.accepted, protocol.model_interruption_reply.rejected }),
        .conflict = jsonReply(.{protocol.model_interruption_reply.conflict}),
    },
    .{
        .path = protocol.CommandKind.permission_decision.route(),
        .kind = .permission_decision,
        .summary = "Allows or denies one Action that waits for permission. Retried by its key.",
        .variants = &.{variant(protocol.permission_decision_request, .{})},
        .reply = jsonReply(.{ protocol.permission_decision_reply.accepted, protocol.permission_decision_reply.rejected }),
        .conflict = jsonReply(.{protocol.permission_decision_reply.conflict}),
    },
    .{
        .path = "/v1/observe-command",
        .kind = .observe_command,
        .summary = "What became of the command sent with this key.",
        .variants = &.{variant(protocol.observe_command_request.head ++ .{Optional(protocol.observe_command_request.since)} ++ protocol.observe_command_request.tail, .{})},
        .reply = .{ .json = observationSchema },
    },
    .{
        .path = "/v1/read-result",
        .kind = .read_result,
        .summary = "The answer text of the Message sent with this key.",
        .variants = &.{variant(protocol.read_result_request, .{})},
        .reply = .text,
    },
    .{
        .path = "/v1/read-action-call-id",
        .kind = .read_action_call_id,
        .summary = "The provider's call id of one Action.",
        .variants = &.{variant(protocol.read_action_call_id_request, .{})},
        .reply = .text,
    },
    .{
        .path = "/v1/read-action-arguments",
        .kind = .read_action_arguments,
        .summary = "The arguments of one Action.",
        .variants = &.{variant(protocol.read_action_arguments_request, .{})},
        .reply = .text,
    },
    .{
        .path = "/v1/inspect-session",
        .kind = .inspect_session,
        .summary = "A Session's report, or one failed provider response.",
        .variants = &.{
            variant(protocol.inspect_session_request.head ++ .{Optional(protocol.inspect_session_request.since)} ++ protocol.inspect_session_request.tail, .{}),
            variant(protocol.inspect_session_request.head ++ protocol.inspect_session_request.profile ++ protocol.inspect_session_request.tail, .{}),
            variant(protocol.inspect_session_request.head ++ protocol.inspect_session_request.failed_response ++ protocol.inspect_session_request.tail, .{}),
        },
        .reply = .report,
    },
    .{
        .path = "/v1/list-sessions",
        .kind = .list_sessions,
        .summary = "One page of Sessions, newest first, or what changed since a token. `through` and `after_reference` appear together, only with `since`; token reads start with zero `after` and `ceiling`.",
        .variants = &.{variant(protocol.list_sessions_request.head ++ .{
            Optional(protocol.list_sessions_request.archive),
        } ++ protocol.list_sessions_request.cursor ++ .{
            Optional(protocol.list_sessions_request.since),
            Optional(protocol.list_sessions_request.through),
            Optional(protocol.list_sessions_request.after_reference),
        } ++ protocol.list_sessions_request.tail, .{ .{ 3, "0" }, .{ 4, "0" }, .{ 5, since_example }, .{ 7, "\"aaaaaa\"" } })},
        .reply = jsonReply(.{
            protocol.session_list_reply.head ++ .{ListOf(protocol.SessionRow)} ++ protocol.session_list_reply.full_tail,
            protocol.session_list_reply.head ++ .{ListOf(protocol.SessionRow)} ++ protocol.session_list_reply.changed_tail,
            protocol.session_list_reply.head ++ .{ListOf(protocol.SessionRow)} ++ protocol.session_list_reply.last_tail,
            protocol.session_list_reply.head ++ .{ListOf(protocol.SessionRow)} ++ protocol.session_list_reply.unchanged_tail,
        }),
    },
    .{
        .path = "/v1/conversation-page",
        .kind = .conversation_page,
        .summary = "One page of a Session's conversation, newest first.",
        .variants = &.{variant(protocol.conversation_page_request, .{})},
        .reply = jsonReply(.{
            protocol.conversation_page_reply.head ++ .{ListOf(ConversationItem)} ++ protocol.conversation_page_reply.last,
            protocol.conversation_page_reply.head ++ .{ListOf(ConversationItem)} ++ protocol.conversation_page_reply.more,
        }),
    },
    .{
        .path = "/v1/conversation-content",
        .kind = .conversation_content,
        .summary = "The content of one conversation item.",
        .variants = &.{variant(protocol.conversation_content_request.head ++ .{Optional(protocol.conversation_content_request.stream)} ++ protocol.conversation_content_request.tail, .{})},
        .reply = .bytes,
    },
    .{
        .path = "/v1/activity-search",
        .kind = .activity_search,
        .summary = "Search public Session activity newest first with bounded snippets.",
        .variants = &.{variant(protocol.activity_search_request.head ++ .{
            Optional(protocol.activity_search_request.kinds),
            Optional(protocol.activity_search_request.before_position),
            Optional(protocol.activity_search_request.before_ordinal),
            Optional(protocol.activity_search_request.limit),
        } ++ protocol.activity_search_request.tail, .{})},
        .reply = jsonReply(.{activity_reply.search_reply.head ++ .{ListOf(ActivitySearchItem)} ++ activity_reply.search_reply.tail}),
    },
    .{
        .path = "/v1/activity-page",
        .kind = .activity_page,
        .summary = "One page of a Session's activity feed, with its work and queue at the page's boundary.",
        .variants = &.{variant(protocol.activity_page_request.head ++ .{Optional(protocol.activity_page_request.since)} ++ protocol.activity_page_request.tail, .{})},
        .reply = jsonReply(.{ activity_reply.page_reply.head ++ .{ListOf(activity_reply.ItemJson)} ++ activity_reply.page_reply.tail, activity_reply.page_reply.unchanged }),
    },
    .{
        .path = "/v1/activity-content",
        .kind = .activity_content,
        .summary = "The content of one activity row.",
        .variants = &.{variant(protocol.activity_content_request, .{})},
        .reply = .bytes,
    },
    .{
        .path = "/v1/skill-suggestions",
        .kind = .skill_suggestions,
        .summary = "Bounded skill metadata from a Session catalog or prospective Workspace discovery.",
        .variants = &.{ variant(protocol.skill_suggestions_session_request, .{.{ 1, "\"k7m2qx\"" }}), variant(protocol.skill_suggestions_workspace_request, .{}) },
        .reply = jsonReply(.{protocol.skill_suggestions_reply.head ++ .{BoundedListOf(protocol.skill_suggestions_reply.entry, 24, false)} ++ .{protocol.skill_suggestions_reply.tail}}),
    },
    .{
        .path = "/v1/model-list",
        .kind = .model_list,
        .summary = "The models each served provider offers.",
        .variants = &.{variant(protocol.model_list_request, .{})},
        .reply = jsonReply(.{.{ protocol.model_list_reply.head, ListOf(ModelListEntry), protocol.model_list_reply.tail }}),
    },
};

const since_example = "00000000000000000000000000000000.1";

comptime {
    // Every request kind has exactly one route.
    for (std.meta.tags(protocol.Kind)) |kind| {
        var count = 0;
        for (routes) |route| count += @intFromBool(route.kind == kind);
        if (count != 1) @compileError("one route per request kind: " ++ @tagName(kind));
    }
}

// Marker types. Each has `openapi_shape` (a named component built from that
// shape), or `openapi_inline` (an inline schema) with `openapi_example` when
// requests use it.

/// One omittable object member, including its leading comma. Unlike a nullable
/// hole, this marker changes presence, not the member's value schema.
fn Optional(comptime shape: anytype) type {
    return struct {
        pub const optional_shape = shape;
        pub const member_name = blk: {
            const first = shape[0];
            const start = if (std.mem.startsWith(u8, first, ",\"")) 2 else if (std.mem.startsWith(u8, first, "\"")) 1 else @compileError("optional member must start with a quoted name");
            const end = std.mem.indexOfScalarPos(u8, first, start, '"').?;
            break :blk first[start..end];
        };
    };
}

fn isOptional(comptime part: anytype) bool {
    return @TypeOf(part) == type and @hasDecl(part, "optional_shape");
}

/// A sender is required, but its value may be null or a full address.
const Sender = struct {
    pub fn openapi_inline(d: *Document) !Value {
        return d.nullable(try d.shapeSchema(protocol.message_request.sender));
    }
    pub fn openapi_example(out: *std.Io.Writer) !void {
        try out.writeAll("null");
    }
};

/// A JSON array of `item`, which is a type or a shape.
fn ListOf(comptime item: anytype) type {
    return struct {
        pub const is_list = true;
        pub fn openapi_inline(d: *Document) !Value {
            const items = if (@TypeOf(item) == type) try d.typeRef(item) else try d.shapeSchema(item);
            return d.object(.{ .type = Value{ .string = "array" }, .items = items });
        }
    };
}

fn BoundedListOf(comptime item: anytype, comptime capacity: usize, comptime unique: bool) type {
    return struct {
        pub const is_list = true;
        pub fn openapi_example(out: *std.Io.Writer) !void {
            try out.writeAll("[]");
        }
        pub fn openapi_inline(d: *Document) !Value {
            const items = if (@TypeOf(item) == type) try d.typeRef(item) else try d.shapeSchema(item);
            return d.object(.{ .type = Value{ .string = "array" }, .items = items, .maxItems = Value{ .integer = capacity }, .uniqueItems = Value{ .bool = unique } });
        }
    };
}

/// A string of any length, which the Host saves as content.
const Content = struct {
    pub fn openapi_inline(d: *Document) !Value {
        return d.object(.{ .type = Value{ .string = "string" }, .description = Value{ .string = "Text of any length, saved as content." } });
    }
    pub fn openapi_example(out: *std.Io.Writer) !void {
        try out.writeAll("\"x\"");
    }
};

/// Plain spec values can be null only where the setting table permits it.
fn Plain(comptime value: anytype, comptime allow_null: bool) type {
    return struct {
        pub fn openapi_inline(d: *Document) !Value {
            const schema = if (@TypeOf(value) == type) try d.typeRef(value) else try d.holeSchema(value, false);
            return if (allow_null) d.nullable(schema) else schema;
        }
        pub fn openapi_example(out: *std.Io.Writer) !void {
            if (@TypeOf(value) == type) try value.openapi_example(out) else try writeHoleExample(out, value, false);
        }
    };
}

const TokenCount = struct {
    pub fn openapi_inline(d: *Document) !Value {
        return d.object(.{ .type = Value{ .string = "integer" }, .minimum = Value{ .integer = 0 } });
    }
    pub fn openapi_example(out: *std.Io.Writer) !void {
        try out.writeAll("1");
    }
};

const Tool = protocol.BuiltInTool;

/// A configure's `tools`: names the Host offers, sorted by bytes, none repeated.
const ToolNameList = struct {
    pub fn openapi_inline(d: *Document) !Value {
        return d.object(.{
            .type = Value{ .string = "array" },
            .items = try toolName(d),
            .maxItems = Value{ .integer = protocol.max_tools },
            .uniqueItems = Value{ .bool = true },
            .@"x-rui-max-bytes" = Value{ .integer = protocol.max_tool_list_name_bytes },
            .description = Value{ .string = "None repeated; the names' bytes total at most x-rui-max-bytes. Each must be a tool the Host offers." },
        });
    }
    pub fn openapi_example(out: *std.Io.Writer) !void {
        try out.print("[\"{s}\"]", .{@tagName(std.meta.tags(Tool)[0])});
    }
};

/// A tool name (`tool_name.valid`).
fn toolName(d: *Document) !Value {
    return d.object(.{
        .type = Value{ .string = "string" },
        .pattern = Value{ .string = std.fmt.comptimePrint("^[A-Za-z0-9_-]{{1,{d}}}$", .{protocol.max_tool_name_bytes}) },
    });
}

/// A sparse plain agent spec. Creation completeness is checked by the parser;
/// updates may omit any member. Both native mutation doors share this shape.
fn configurationShape(comptime name: []const u8) type {
    return struct {
        pub const openapi_name = name;
        pub const openapi_shape = .{"{"} ++ configurationMembers(0).shape;
    };
}

fn configurationMembers(comptime index: usize) type {
    if (index == session_settings.spec_entries.len) return struct {
        const shape = .{"}"};
    };
    const entry = session_settings.spec_entries[index];
    const value = switch (entry.kind) {
        .text, .choice => |capacity| Plain(Hole{ .string = capacity }, entry.nullable),
        .decimal_policy => Plain(TokenCount, entry.nullable),
        .tools => Plain(ToolNameList, entry.nullable),
        .content => Plain(if (entry.json_object) SchemaObject else Content, entry.nullable),
    };
    const member = .{ (if (index == 0) "" else ",") ++ "\"" ++ entry.spec ++ "\":", value };
    return struct {
        const shape = .{Optional(member)} ++ configurationMembers(index + 1).shape;
    };
}

/// Schemas have arbitrary JSON members; no object is a content reference.
const SchemaObject = struct {
    pub fn openapi_inline(d: *Document) !Value {
        return d.object(.{ .type = Value{ .string = "object" }, .additionalProperties = Value{ .bool = true } });
    }
    pub fn openapi_example(out: *std.Io.Writer) !void {
        try out.writeAll("{}");
    }
};

const Configuration = configurationShape("Configuration");
const MessageConfiguration = Configuration;

/// One `conversation-page` item: what every kind carries, then what only
/// its kind carries.
const ConversationItem = struct {
    pub fn openapi_inline(d: *Document) !Value {
        const page = protocol.conversation_page_reply;
        return d.anyOf(&.{
            try d.shapeSchema(tuple(page.item(.user)) ++ page.item_end),
            try d.shapeSchema(tuple(page.item(.user)) ++ page.admission ++ page.item_end),
            try d.shapeSchema(tuple(page.item(.assistant)) ++ page.item_end),
            try d.shapeSchema(tuple(page.item(.tool_result)) ++ page.item_end),
            try d.shapeSchema(tuple(page.item(.tool_result)) ++ page.presentation ++ page.item_end),
            try d.shapeSchema(page.hosted_call ++ page.item_end),
            try d.shapeSchema(page.hosted_call ++ page.presentation ++ page.item_end),
        });
    }
};

/// One provider of a `model-list` reply, as `model_list.writeProviders`
/// writes it in code. A test checks a rendered list against this.
const ModelListEntry = struct {
    pub const openapi_shape = .{ "{\"provider\":\"", Hole{ .tag = protocol.Provider }, "\",\"source\":\"", Hole{ .tag = model_list.Source }, "\",\"models\":", ListOf(.{ "{\"id\":", Hole{ .string = protocol.max_model_bytes }, ",\"known\":", Hole.boolean, "}" }), "}" };
};

/// `SessionRow`'s `tools`, written as raw JSON text.
const ToolNames = struct {
    pub fn openapi_inline(d: *Document) !Value {
        return ToolNameList.openapi_inline(d);
    }
};

/// A `command_observation` reply: `absent`, or one object per command kind
/// whose parts depend on what became of the command.
fn observationSchema(d: *Document) anyerror!Value {
    const o = protocol.command_observation_reply;
    var kinds: [std.meta.tags(protocol.CommandKind).len + 2]Value = undefined;
    kinds[0] = try d.shapeSchema(o.absent);
    kinds[kinds.len - 1] = try d.shapeSchema(o.not_modified);
    inline for (comptime std.meta.tags(protocol.CommandKind), 1..) |kind, index| {
        const bodies = switch (kind) {
            .configure => .{ .{}, o.revision },
            .message => o.message_variants,
            .session_stop => .{ .{}, o.session_stop },
            .session_archive => .{ .{}, o.session_archive },
            .model_interruption => .{ .{}, o.model_interruption },
            .permission_decision => .{ .{}, o.permission_decision },
        };
        var variants: [2 * bodies.len]Value = undefined;
        inline for (bodies, 0..) |body, at| {
            variants[2 * at] = try d.shapeSchema(tuple(o.head(kind)) ++ body ++ o.tail);
            variants[2 * at + 1] = try d.shapeSchema(tuple(o.head(kind)) ++ o.code ++ body ++ o.tail);
        }
        kinds[index] = try d.merge(&variants);
    }
    return d.anyOf(&kinds);
}

/// Consumes the settings owner's grammar, not its storage representation.
/// Groups arrive parent-first; assembling them in reverse attaches complete
/// children without retaining pointers into growable JSON object maps.
const SettingsSchema = struct {
    document: *Document,
    groups: std.ArrayList(host_settings.Group) = .empty,
    values: ObjectMap = .empty,

    pub fn group(self: *SettingsSchema, fact: host_settings.Group) !void {
        try self.groups.append(self.document.arena, fact);
    }

    pub fn leaf(self: *SettingsSchema, fact: host_settings.Leaf) !void {
        try self.values.put(self.document.arena, fact.pattern, try self.document.settingsLeaf(fact));
    }

    fn child(self: *SettingsSchema, parent: []const u8, name: []const u8) !Value {
        const at = try std.fmt.allocPrint(self.document.arena, "{s}{s}{s}", .{ parent, if (parent.len == 0) "" else ".", name });
        return self.values.get(at) orelse error.MissingSettingsSchema;
    }

    fn finish(self: *SettingsSchema) !Value {
        const d = self.document;
        var index = self.groups.items.len;
        while (index > 0) {
            index -= 1;
            const fact = self.groups.items[index];
            var value: Value = undefined;
            switch (fact.kind) {
                .named => {
                    value = try d.object(.{
                        .type = Value{ .string = "object" },
                        .additionalProperties = try self.child(fact.pattern, "*"),
                        .propertyNames = try d.object(.{
                            .pattern = Value{ .string = try std.fmt.allocPrint(d.arena, "^[{s}]{{1,{d}}}(?![\\s\\S])", .{
                                if (fact.name_format.? == .mcp) "A-Za-z0-9_-" else "a-z0-9_-", fact.name_max_bytes.?,
                            }) },
                        }),
                    });
                },
                .object, .providers, .one_adapter => {
                    var properties: ObjectMap = .empty;
                    var alternatives: std.json.Array = .init(d.arena);
                    for (fact.keys) |key| {
                        const item = try self.child(fact.pattern, key);
                        try properties.put(d.arena, key, item);
                        if (fact.kind == .one_adapter) try alternatives.append(try d.singleProperty(key, item));
                    }
                    value = if (fact.kind == .one_adapter)
                        try d.object(.{ .oneOf = Value{ .array = alternatives } })
                    else
                        try d.object(.{
                            .type = Value{ .string = "object" },
                            .properties = Value{ .object = properties },
                            .additionalProperties = Value{ .bool = false },
                        });
                },
            }
            if (fact.max_entries) |maximum| try value.object.put(d.arena, "maxProperties", try d.unsigned(maximum));
            if (fact.min_entries != 0) try value.object.put(d.arena, "minProperties", try d.unsigned(fact.min_entries));
            try value.object.put(d.arena, "description", .{ .string = fact.doc });
            if (fact.nullable) value = try d.nullable(value);
            try self.values.put(d.arena, fact.pattern, value);
        }
        return self.values.get("").?;
    }
};

/// The document under construction, with its arena and named schemas.
pub const Document = struct {
    arena: std.mem.Allocator,
    schemas: ObjectMap,

    pub fn init(arena: std.mem.Allocator) Document {
        return .{ .arena = arena, .schemas = .empty };
    }

    /// An object with these fields in order, from a struct literal.
    fn object(d: *Document, fields: anytype) !Value {
        var map: ObjectMap = .empty;
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |name| try map.put(d.arena, name, @field(fields, name));
        return .{ .object = map };
    }

    fn array(d: *Document, items: []const Value) !Value {
        var list: std.json.Array = .init(d.arena);
        try list.appendSlice(items);
        return .{ .array = list };
    }

    fn ref(d: *Document, name: []const u8) !Value {
        return d.object(.{ .@"$ref" = Value{ .string = try std.fmt.allocPrint(d.arena, "#/components/schemas/{s}", .{name}) } });
    }

    fn nullable(d: *Document, schema: Value) !Value {
        return d.anyOf(&.{ schema, try d.object(.{ .type = Value{ .string = "null" } }) });
    }

    /// One schema when every alternative is the same, else `anyOf`.
    fn anyOf(d: *Document, alternatives: []const Value) !Value {
        var distinct: std.ArrayList(Value) = .empty;
        var texts: std.ArrayList([]const u8) = .empty;
        for (alternatives) |alternative| {
            const text = try std.json.Stringify.valueAlloc(d.arena, alternative, .{});
            for (texts.items) |seen| {
                if (std.mem.eql(u8, seen, text)) break;
            } else {
                try distinct.append(d.arena, alternative);
                try texts.append(d.arena, text);
            }
        }
        if (distinct.items.len == 1) return distinct.items[0];
        return d.object(.{ .anyOf = try d.array(distinct.items) });
    }

    /// One object schema that accepts each of `variants`, all objects: every
    /// property any of them has, required when all have it.
    fn merge(d: *Document, variants: []const Value) !Value {
        var properties: ObjectMap = .empty;
        var alternatives: std.StringArrayHashMapUnmanaged(std.ArrayList(Value)) = .empty;
        var counts: std.StringArrayHashMapUnmanaged(usize) = .empty;
        for (variants) |each| {
            const props = each.object.get("properties").?.object;
            for (props.keys(), props.values()) |name, schema| {
                const slot = try alternatives.getOrPut(d.arena, name);
                if (!slot.found_existing) slot.value_ptr.* = .empty;
                try slot.value_ptr.append(d.arena, schema);
                const count = try counts.getOrPut(d.arena, name);
                count.value_ptr.* = if (count.found_existing) count.value_ptr.* + 1 else 1;
            }
        }
        var required: std.json.Array = .init(d.arena);
        for (alternatives.keys(), alternatives.values()) |name, schemas| {
            try properties.put(d.arena, name, try d.anyOf(schemas.items));
            if (counts.get(name).? == variants.len) try required.append(.{ .string = name });
        }
        return d.object(.{
            .type = Value{ .string = "object" },
            .properties = Value{ .object = properties },
            .required = Value{ .array = required },
            .additionalProperties = Value{ .bool = false },
        });
    }

    /// A reference to `T`'s named schema, built on first use.
    fn typeRef(d: *Document, comptime T: type) !Value {
        if (@hasDecl(T, "openapi_inline")) return T.openapi_inline(d);
        if (@hasDecl(T, "openapi_list")) return d.object(.{ .type = Value{ .string = "array" }, .items = try d.typeRef(T.openapi_list) });
        if (@hasDecl(T, "openapi_tools")) return ToolNameList.openapi_inline(d);
        if (@hasDecl(T, "openapi_tool_name")) return toolName(d);
        if (@hasDecl(T, "openapi_content")) return Content.openapi_inline(d);
        const name = comptime componentName(T);
        if (!d.schemas.contains(name)) {
            // Claim the name first, so a type that refers to itself ends.
            try d.schemas.put(d.arena, name, .null);
            try d.schemas.put(d.arena, name, try d.typeSchema(T));
        }
        return d.ref(name);
    }

    fn typeSchema(d: *Document, comptime T: type) !Value {
        if (@hasDecl(T, "openapi_shape")) {
            return d.shapeSchema(T.openapi_shape);
        }
        if (@hasDecl(T, "openapi_shapes")) {
            var values: [T.openapi_shapes.len]Value = undefined;
            inline for (T.openapi_shapes, 0..) |shape, index| values[index] = try d.shapeSchema(shape);
            return d.anyOf(&values);
        }
        if (T == protocol.WorkStateJson) return d.anyOf(&.{
            try d.shapeSchema(T.plain_shape),
            try d.shapeSchema(T.retrying_shape),
            try d.shapeSchema(T.bash_shape),
            try d.shapeSchema(T.older_bash_shape),
            try d.shapeSchema(T.failed_shape),
            try d.shapeSchema(T.stopped_shape),
        });
        if (T == protocol.MessageRecoveryJson) {
            const Calls = struct {
                pub const is_list = true;
                pub fn openapi_inline(document: *Document) !Value {
                    return document.object(.{
                        .type = Value{ .string = "array" },
                        .items = try document.shapeSchema(protocol.MessageRecoveryJson.item),
                        .maxItems = Value{ .integer = protocol.message_recovery_limit },
                    });
                }
            };
            return d.shapeSchema(T.head ++ .{Calls} ++ T.tail);
        }
        if (T == activity_reply.CallActivityJson) return d.shapeSchema(T.head ++ .{ListOf(T.entry_shape)} ++ T.tail);
        if (T == activity_reply.ItemJson) {
            const kinds = comptime std.meta.tags(protocol.ActivityItem.Kind);
            var values: [kinds.len]Value = undefined;
            inline for (kinds, 0..) |kind, index| {
                values[index] = try d.shapeSchema(tuple(T.head(kind)) ++ @field(T.value_shapes, @tagName(kind)) ++ T.tail);
                if (kind == .model_call) try values[index].object.put(d.arena, "description", .{ .string = "One resolved model Operation at its admission position. Timings describe the FINAL attempt only: latency_ms is request sent to resolution; first_event_ms is request sent to the first HTTP response event (including an interim head), not the first token. Missing evidence, usage or timings is null. A resolution may become visible within a previously captured end (D219)." });
            }
            return d.anyOf(&values);
        }
        if (T == protocol.SessionRow) return d.shapeSchemaWith(T.json_shape, ToolNames);
        if (@hasDecl(T, "json_shape")) return d.shapeSchema(T.json_shape);
        @compileError("no wire schema for " ++ @typeName(T));
    }

    fn unsigned(d: *Document, number: u64) !Value {
        return .{ .number_string = try std.fmt.allocPrint(d.arena, "{d}", .{number}) };
    }

    /// A closed exactly-one source or Adapter alternative.
    fn singleProperty(d: *Document, name: []const u8, schema: Value) !Value {
        var properties: ObjectMap = .empty;
        try properties.put(d.arena, name, schema);
        return d.object(.{
            .type = Value{ .string = "object" },
            .properties = Value{ .object = properties },
            .required = try d.array(&.{.{ .string = name }}),
            .additionalProperties = Value{ .bool = false },
        });
    }

    fn boundedString(d: *Document, maximum: usize) !Value {
        return d.object(.{
            .type = Value{ .string = "string" },
            .maxLength = try d.unsigned(maximum),
            // JSON Schema lengths count Unicode scalars; the owner bounds bytes.
            .@"x-maxBytes" = try d.unsigned(maximum),
        });
    }

    fn osBytes(d: *Document, maximum: ?usize, pattern: []const u8, hex_maximum: ?usize) !Value {
        const text = if (maximum) |bound| try d.boundedString(bound) else try d.object(.{ .type = Value{ .string = "string" } });
        var hex = if (hex_maximum) |bound| try d.boundedString(bound) else try d.object(.{ .type = Value{ .string = "string" } });
        try hex.object.put(d.arena, "pattern", .{ .string = pattern });
        var value = try d.object(.{
            .oneOf = try d.array(&.{ text, try d.singleProperty("hex", hex) }),
            .@"x-rui-kind" = Value{ .string = "bytes" },
        });
        if (maximum == null) try value.object.put(d.arena, "x-rui-native-path-limit", .{ .bool = true });
        return value;
    }

    fn settingsLeaf(d: *Document, leaf: host_settings.Leaf) !Value {
        const fact = leaf.json_schema;
        var value: Value = undefined;
        if (fact.secret_sources.len != 0) {
            var alternatives: std.json.Array = .init(d.arena);
            for (fact.secret_sources) |source| {
                const schema = if (std.mem.eql(u8, source, "env"))
                    try d.osBytes(fact.source_env_max_bytes.?, host_settings.Schema.os_bytes_pattern, 2 * fact.source_env_max_bytes.?)
                else if (std.mem.eql(u8, source, "file"))
                    try d.osBytes(if (fact.source_file_native_path_limit) null else fact.source_file_max_bytes.?, host_settings.Schema.os_bytes_pattern, if (fact.source_file_native_path_limit) null else 2 * fact.source_file_max_bytes.?)
                else if (std.mem.eql(u8, source, "value"))
                    try d.boundedString(fact.max_bytes.?)
                else if (std.mem.eql(u8, source, "owner"))
                    try d.object(.{ .@"const" = Value{ .bool = true } })
                else
                    return error.UnknownSecretSource;
                var alternative = try d.singleProperty(source, schema);
                if (std.mem.eql(u8, source, "value")) try alternative.object.put(d.arena, "description", .{ .string = "Literal secret; accepted only from a pipe, never from a settings file." });
                try alternatives.append(alternative);
            }
            value = try d.object(.{ .oneOf = Value{ .array = alternatives } });
        } else if (fact.hex_object) |hex| {
            value = try d.osBytes(if (fact.native_path_limit) null else fact.max_bytes.?, hex.pattern, if (fact.native_path_limit) null else hex.max_length);
        } else if (fact.format != null and std.mem.eql(u8, fact.format.?, "agent-spec")) {
            value = try d.ref("AgentSpec");
        } else {
            value = try d.object(.{ .type = Value{ .string = @tagName(fact.type) } });
            if (fact.max_bytes) |maximum| value = try d.boundedString(maximum);
            if (fact.min) |minimum| try value.object.put(d.arena, "minimum", try d.unsigned(minimum));
            if (fact.max) |maximum| try value.object.put(d.arena, "maximum", try d.unsigned(maximum));
            if (fact.choices.len != 0) {
                var names: std.json.Array = .init(d.arena);
                for (fact.choices) |name| try names.append(.{ .string = name });
                try value.object.put(d.arena, "enum", .{ .array = names });
            }
        }
        if (fact.format) |format| try value.object.put(d.arena, "format", .{ .string = format });
        try value.object.put(d.arena, "description", .{ .string = leaf.doc });
        if (fact.nullable) value = try d.nullable(value);
        if (fact.secret_sources.len != 0) try value.object.put(d.arena, "x-rui-kind", .{ .string = "secret" });
        if (fact.hex_object != null) try value.object.put(d.arena, "x-rui-kind", .{ .string = "bytes" });
        if (fact.native_path_limit) try value.object.put(d.arena, "x-rui-native-path-limit", .{ .bool = true });
        return value;
    }

    /// JSON decoded directly into a Zig wire type. Defaults permit omission,
    /// whereas optional types permit null; these are independent on the wire.
    fn wireSchema(d: *Document, comptime T: type) anyerror!Value {
        return switch (@typeInfo(T)) {
            .bool => d.object(.{ .type = Value{ .string = "boolean" } }),
            .int => d.object(.{ .type = Value{ .string = "integer" } }),
            .@"enum" => d.enumeration(T, false),
            .optional => |optional| d.nullable(try d.wireSchema(optional.child)),
            .pointer => |pointer| if (pointer.size == .slice and pointer.child == u8)
                d.object(.{ .type = Value{ .string = "string" } })
            else if (pointer.size == .slice)
                d.object(.{ .type = Value{ .string = "array" }, .items = try d.wireSchema(pointer.child) })
            else
                @compileError("not a JSON wire slice: " ++ @typeName(T)),
            .@"struct" => |fields| blk: {
                var properties: ObjectMap = .empty;
                var required: std.json.Array = .init(d.arena);
                inline for (fields.field_names, fields.field_types, fields.field_attrs) |name, Field, attrs| {
                    const schema = try d.wireSchema(Field);
                    try properties.put(d.arena, name, schema);
                    if (attrs.default_value_ptr == null) try required.append(.{ .string = name });
                }
                break :blk d.object(.{
                    .type = Value{ .string = "object" },
                    .properties = Value{ .object = properties },
                    .required = Value{ .array = required },
                    .additionalProperties = Value{ .bool = false },
                });
            },
            else => @compileError("not a JSON wire type: " ++ @typeName(T)),
        };
    }

    fn settingsSchemas(d: *Document) !void {
        // Reuse start_agent's field vocabulary. Presets are complete specs,
        // not partial overrides, and parseAgentSpec also permits creation's
        // provider and workspace fields (start_agent inherits them instead).
        const start_agent = try std.json.parseFromSliceLeaky(Value, d.arena, core_tools.start_agent_schema, .{});
        var spec = start_agent.object.get("properties").?.object.get("spec").?;
        try spec.object.put(d.arena, "required", try d.array(&.{
            .{ .string = "model" }, .{ .string = "effort" }, .{ .string = "compactAt" }, .{ .string = "tools" }, .{ .string = "permissionMode" },
        }));
        const spec_properties = spec.object.getPtr("properties").?;
        try spec_properties.object.put(d.arena, "provider", try d.enumeration(protocol.Provider, false));
        try spec_properties.object.put(d.arena, "workspace", try d.wireSchema([]const u8));
        try d.schemas.put(d.arena, "AgentSpec", spec);
        var visitor: SettingsSchema = .{ .document = d };
        try host_settings.schema(&visitor);
        try d.schemas.put(d.arena, "HostSettings", try visitor.finish());
        try d.schemas.put(d.arena, "StartError", try d.wireSchema(struct {
            rui_start_error: struct { code: start_report.StartError, message: []const u8 },
        }));
    }

    /// The schema of a JSON shape.
    pub fn shapeSchema(d: *Document, comptime shape: anytype) !Value {
        return d.shapeSchemaWith(shape, null);
    }

    /// The schema of a JSON shape whose unquoted text holes, raw JSON, have
    /// the schema of `Raw`.
    fn shapeSchemaWith(d: *Document, comptime shape: anytype, comptime Raw: ?type) !Value {
        var text: std.Io.Writer.Allocating = .init(d.arena);
        var holes: std.ArrayList(Value) = .empty;
        var lists: std.ArrayList(bool) = .empty;
        try d.appendShape(shape, Raw, &text, &holes, &lists);
        const json = try std.json.parseFromSliceLeaky(Value, d.arena, text.written(), .{});
        var schema = try d.fromJson(json, holes.items, lists.items);
        inline for (shape) |part| {
            if (comptime isOptional(part)) {
                const required = &schema.object.getPtr("required").?.array;
                for (required.items, 0..) |field, index| {
                    if (std.mem.eql(u8, field.string, part.member_name)) {
                        _ = required.orderedRemove(index);
                        break;
                    }
                }
            }
        }
        return schema;
    }

    fn appendShape(d: *Document, comptime shape: anytype, comptime Raw: ?type, text: *std.Io.Writer.Allocating, holes: *std.ArrayList(Value), lists: *std.ArrayList(bool)) anyerror!void {
        inline for (shape, 0..) |part, index| {
            if (comptime isOptional(part)) {
                try d.appendShape(part.optional_shape, Raw, text, holes, lists);
            } else if (comptime isLiteral(part)) {
                try text.writer.writeAll(part);
            } else {
                const quoted = comptime isQuoted(shape, index);
                if (quoted) {
                    try text.writer.print("@H{d}@", .{holes.items.len});
                } else try text.writer.print("\"@H{d}@\"", .{holes.items.len});
                if (comptime @TypeOf(part) == type) {
                    // A list marker's schema is the whole array.
                    try holes.append(d.arena, try d.typeRef(part));
                    try lists.append(d.arena, @hasDecl(part, "is_list"));
                } else if (comptime !quoted and @as(Hole, part) == .text) {
                    const R = Raw orelse @compileError("raw JSON text needs its schema named with shapeSchemaWith");
                    try holes.append(d.arena, try d.typeRef(R));
                    try lists.append(d.arena, false);
                } else {
                    try holes.append(d.arena, try d.holeSchema(part, quoted));
                    try lists.append(d.arena, false);
                }
            }
        }
    }

    fn fromJson(d: *Document, json: Value, holes: []const Value, lists: []const bool) !Value {
        switch (json) {
            .object => |source| {
                var properties: ObjectMap = .empty;
                var required: std.json.Array = .init(d.arena);
                for (source.keys(), source.values()) |name, value| {
                    try properties.put(d.arena, name, try d.fromJson(value, holes, lists));
                    try required.append(.{ .string = name });
                }
                return d.object(.{
                    .type = Value{ .string = "object" },
                    .properties = Value{ .object = properties },
                    .required = Value{ .array = required },
                    .additionalProperties = Value{ .bool = false },
                });
            },
            .array => |source| {
                if (source.items.len == 1) if (marker(source.items[0])) |index| if (lists[index]) return holes[index];
                if (source.items.len == 0) return d.object(.{ .type = Value{ .string = "array" }, .maxItems = Value{ .integer = 0 } });
                var items: std.json.Array = .init(d.arena);
                for (source.items) |item| try items.append(try d.fromJson(item, holes, lists));
                return d.object(.{
                    .type = Value{ .string = "array" },
                    .prefixItems = Value{ .array = items },
                    .items = Value{ .bool = false },
                    .minItems = Value{ .integer = @intCast(source.items.len) },
                });
            },
            .string => |text| {
                // A list marker outside brackets writes its own.
                if (marker(json)) |index| return holes[index];
                if (std.mem.indexOf(u8, text, "@H") != null) return error.HoleInsideText;
                return d.object(.{ .@"const" = json });
            },
            .bool, .integer => return d.object(.{ .@"const" = json }),
            .null => return d.object(.{ .type = Value{ .string = "null" } }),
            else => return error.UnexpectedJson,
        }
    }

    fn holeSchema(d: *Document, comptime hole: Hole, comptime quoted: bool) !Value {
        if (quoted) return switch (hole) {
            .decimal => d.decimal(),
            .tag => |T| d.enumeration(T, false),
            .text => |bytes| d.object(.{ .type = Value{ .string = "string" }, .@"x-rui-max-bytes" = Value{ .integer = bytes } }),
            .hex => |bytes| d.object(.{ .type = Value{ .string = "string" }, .pattern = Value{ .string = std.fmt.comptimePrint("^[0-9a-f]{{{d}}}$", .{2 * bytes}) } }),
            else => @compileError("a quoted hole renders text: " ++ @tagName(hole)),
        };
        return switch (hole) {
            .boolean => d.object(.{ .type = Value{ .string = "boolean" } }),
            .optional_id => d.nullable(try d.decimal()),
            .tag_set => |T| d.object(.{
                .type = Value{ .string = "array" },
                .items = try d.enumeration(T, false),
                .uniqueItems = Value{ .bool = true },
                .description = Value{ .string = "Each at most once, in the order the enum lists them." },
            }),
            .optional_tag => |T| d.enumeration(T, true),
            .string => |bytes| d.string(bytes),
            .optional_string => |bytes| d.nullable(try d.string(bytes)),
            .json => |T| d.typeRef(T),
            .optional_json => |T| d.nullable(try d.typeRef(T)),
            .decimal, .tag, .hex => @compileError("this hole renders inside a JSON string: " ++ @tagName(hole)),
            .text => unreachable,
        };
    }

    /// A u64 written as a decimal string, which JSON numbers cannot carry exactly.
    fn decimal(d: *Document) !Value {
        if (!d.schemas.contains("Decimal")) try d.schemas.put(d.arena, "Decimal", try d.object(.{
            .type = Value{ .string = "string" },
            .pattern = Value{ .string = "^(0|[1-9][0-9]*)$" },
            .description = Value{ .string = "An unsigned 64-bit integer in decimal." },
        }));
        return d.ref("Decimal");
    }

    fn string(d: *Document, comptime bytes: usize) !Value {
        // Every character takes at least one byte and at most as many
        // UTF-16 units as bytes, so the byte bound bounds both.
        return d.object(.{
            .type = Value{ .string = "string" },
            .maxLength = Value{ .integer = bytes },
            .@"x-rui-max-bytes" = Value{ .integer = bytes },
        });
    }

    fn enumeration(d: *Document, comptime T: type, comptime allow_null: bool) !Value {
        var names: std.json.Array = .init(d.arena);
        inline for (comptime std.meta.tags(T)) |tag| try names.append(.{ .string = @tagName(tag) });
        if (allow_null) {
            try names.append(.null);
            return d.object(.{ .@"enum" = Value{ .array = names } });
        }
        return d.object(.{ .type = Value{ .string = "string" }, .@"enum" = Value{ .array = names } });
    }

    /// The whole document.
    pub fn build(d: *Document) !Value {
        var paths: ObjectMap = .empty;
        var request_schemas: [routes.len]Value = undefined;
        for (&routes, 0..) |*route, index| {
            var variants: std.ArrayList(Value) = .empty;
            for (route.variants) |each| try variants.append(d.arena, try each.schema(d));
            request_schemas[index] = try d.anyOf(variants.items);
        }
        for (&routes, request_schemas) |*route, request_schema| {
            const base = try pascal(d.arena, @tagName(route.kind));
            const request_name = try std.fmt.allocPrint(d.arena, "{s}Request", .{base});
            try d.schemas.put(d.arena, request_name, request_schema);
            var responses: ObjectMap = .empty;
            switch (route.reply) {
                .json => |schema| {
                    const reply_name = try std.fmt.allocPrint(d.arena, "{s}Reply", .{base});
                    try d.schemas.put(d.arena, reply_name, try schema(d));
                    try responses.put(d.arena, "200", try d.response("The reply.", "application/json", try d.ref(reply_name)));
                },
                .bytes => try responses.put(d.arena, "200", try d.response("The content bytes, from the requested offset.", "application/octet-stream", try d.binary())),
                .text => try responses.put(d.arena, "200", try d.response("The content, as text.", "text/plain", try d.object(.{ .type = Value{ .string = "string" } }))),
                .report => {
                    var content: ObjectMap = .empty;
                    const reply_name = try std.fmt.allocPrint(d.arena, "{s}Reply", .{base});
                    const shapes = session_report_reply.shapes;
                    try d.schemas.put(d.arena, reply_name, try d.anyOf(&.{
                        try d.shapeSchema(shapes.current),
                        try d.shapeSchema(shapes.full),
                        try d.shapeSchema(shapes.missing_current),
                        try d.shapeSchema(shapes.missing_full),
                    }));
                    try content.put(d.arena, "application/json", try d.object(.{ .schema = try d.ref(reply_name) }));
                    try content.put(d.arena, "application/octet-stream", try d.object(.{ .schema = try d.binary() }));
                    try responses.put(d.arena, "200", try d.object(.{
                        .description = Value{ .string = "The Session report, or, for a failed response export, that response's bytes." },
                        .content = Value{ .object = content },
                    }));
                },
            }
            if (route.conflict) |conflict| {
                const conflict_name = try std.fmt.allocPrint(d.arena, "{s}ConflictReply", .{base});
                try d.schemas.put(d.arena, conflict_name, try conflict.json(d));
                try responses.put(d.arena, "409", try d.response("The key was used before with different input (the conflict reply), or the request names another Store or Host instance (a refusal).", "application/json", try d.anyOf(&.{ try d.ref(conflict_name), try d.ref("ErrorReply") })));
            }
            try responses.put(d.arena, "default", try d.response("A refusal or failure.", "application/json", try d.ref("ErrorReply")));
            var route_parameters: std.json.Array = .init(d.arena);
            try route_parameters.append(try d.object(.{ .@"$ref" = Value{ .string = "#/components/parameters/WireVersion" } }));
            const instance = if (route.kind == .host_stop) "HostInstanceRequired" else "HostInstance";
            try route_parameters.append(try d.object(.{ .@"$ref" = Value{ .string = try std.fmt.allocPrint(d.arena, "#/components/parameters/{s}", .{instance}) } }));
            if (route.kind == .message) try route_parameters.append(try d.object(.{ .@"$ref" = Value{ .string = "#/components/parameters/EnvironmentBytes" } }));
            const operation = try d.object(.{
                .operationId = Value{ .string = try camel(d.arena, @tagName(route.kind)) },
                .summary = Value{ .string = route.summary },
                .parameters = Value{ .array = route_parameters },
                .requestBody = try d.object(.{
                    .required = Value{ .bool = true },
                    .content = try d.object(.{ .@"application/json" = try d.object(.{ .schema = try d.ref(request_name) }) }),
                }),
                .responses = Value{ .object = responses },
            });
            try paths.put(d.arena, route.path, try d.object(.{ .post = operation }));
        }
        try d.schemas.put(d.arena, "ErrorReply", try d.shapeSchema(protocol.error_reply));
        try d.settingsSchemas();
        d.schemas.sort(SortKeys{ .keys = d.schemas.keys() });
        return d.object(.{
            .openapi = Value{ .string = "3.1.0" },
            .info = try d.object(.{
                .title = Value{ .string = "Rui Host" },
                .version = Value{ .string = protocol.wire_version },
                .description = Value{ .string = description },
            }),
            .paths = Value{ .object = paths },
            .components = try d.object(.{
                .schemas = Value{ .object = d.schemas },
                .parameters = try d.parameters(),
            }),
        });
    }

    fn binary(d: *Document) !Value {
        return d.object(.{ .type = Value{ .string = "string" }, .format = Value{ .string = "binary" } });
    }

    fn response(d: *Document, text: []const u8, media: []const u8, schema: Value) !Value {
        var content: ObjectMap = .empty;
        try content.put(d.arena, media, try d.object(.{ .schema = schema }));
        return d.object(.{ .description = Value{ .string = text }, .content = Value{ .object = content } });
    }

    fn parameters(d: *Document) !Value {
        return d.object(.{
            .WireVersion = try d.object(.{
                .name = Value{ .string = "X-Rui-Wire-Version" },
                .in = Value{ .string = "header" },
                .required = Value{ .bool = true },
                .description = Value{ .string = "The wire version this document describes. Any other version is refused." },
                .schema = try d.object(.{ .type = Value{ .string = "string" }, .@"const" = Value{ .string = protocol.wire_version } }),
            }),
            .HostInstance = try d.object(.{
                .name = Value{ .string = "X-Rui-Host-Instance" },
                .in = Value{ .string = "header" },
                .required = Value{ .bool = false },
                .description = Value{ .string = "The Host instance (from host-info) the request is meant for; a different instance refuses it." },
                .schema = try d.object(.{ .type = Value{ .string = "string" }, .pattern = Value{ .string = std.fmt.comptimePrint("^[0-9a-f]{{{d}}}$", .{2 * @typeInfo(protocol.InstanceId).array.len}) } }),
            }),
            .HostInstanceRequired = try d.object(.{
                .name = Value{ .string = "X-Rui-Host-Instance" },
                .in = Value{ .string = "header" },
                .required = Value{ .bool = true },
                .description = Value{ .string = "The Host instance (from host-info) the request is meant for; a different instance refuses it, and a request without it is refused." },
                .schema = try d.object(.{ .type = Value{ .string = "string" }, .pattern = Value{ .string = std.fmt.comptimePrint("^[0-9a-f]{{{d}}}$", .{2 * @typeInfo(protocol.InstanceId).array.len}) } }),
            }),
            .EnvironmentBytes = try d.object(.{
                .name = Value{ .string = "X-Rui-Environment-Bytes" },
                .in = Value{ .string = "header" },
                .required = Value{ .bool = true },
                .description = Value{ .string = "How many bytes of client environment start the body, before the JSON request." },
                .schema = try d.object(.{ .type = Value{ .string = "string" }, .pattern = Value{ .string = "^(0|[1-9][0-9]*)$" } }),
            }),
        });
    }
};

const description =
    \\The Rui Host's local protocol: HTTP/1.1 over the Unix socket of a running Host, one POST per request, generated from the Host's own wire types.
    \\
    \\Request bodies list their fields in the order this document lists them; the Host refuses another order. Numbers that may exceed 2^53 travel as decimal strings. String bounds are in UTF-8 bytes (`x-rui-max-bytes`).
;

const SortKeys = struct {
    keys: []const []const u8,
    pub fn lessThan(ctx: SortKeys, a: usize, b: usize) bool {
        return std.mem.lessThan(u8, ctx.keys[a], ctx.keys[b]);
    }
};

/// A shape returned as a declared tuple type, as a tuple literal that `++` joins.
fn tuple(comptime shape: anytype) TupleFrom(shape, 0) {
    return tupleFrom(shape, 0);
}

fn tupleFrom(comptime shape: anytype, comptime index: usize) TupleFrom(shape, index) {
    @setEvalBranchQuota(100_000);
    if (index == shape.len) return .{};
    return .{shape[index]} ++ tupleFrom(shape, index + 1);
}

fn TupleFrom(comptime shape: anytype, comptime index: usize) type {
    @setEvalBranchQuota(100_000);
    if (index == shape.len) return @TypeOf(.{});
    return @TypeOf(.{shape[index]} ++ tupleFrom(shape, index + 1));
}

fn isLiteral(comptime part: anytype) bool {
    return @typeInfo(@TypeOf(part)) == .pointer;
}

/// Whether the hole at `index` sits inside a JSON string of the shape.
fn isQuoted(comptime shape: anytype, comptime index: usize) bool {
    if (index == 0 or index + 1 >= shape.len) return false;
    const before = shape[index - 1];
    const after = shape[index + 1];
    if (!isLiteral(before) or !isLiteral(after)) return false;
    return before.len != 0 and before[before.len - 1] == '"' and after.len != 0 and after[0] == '"';
}

fn marker(json: Value) ?usize {
    const text = switch (json) {
        .string => |text| text,
        else => return null,
    };
    if (text.len < 4 or !std.mem.startsWith(u8, text, "@H") or text[text.len - 1] != '@') return null;
    return std.fmt.parseInt(usize, text[2 .. text.len - 1], 10) catch null;
}

fn componentName(comptime T: type) []const u8 {
    if (@hasDecl(T, "openapi_name")) return T.openapi_name;
    const full = @typeName(T);
    const start = if (std.mem.indexOfScalar(u8, full, '.')) |dot| dot + 1 else 0;
    var name: []const u8 = "";
    for (full[start..]) |byte| {
        if (byte != '.') name = name ++ .{byte};
    }
    return name;
}

fn pascal(arena: std.mem.Allocator, snake: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var upper = true;
    for (snake) |byte| {
        if (byte == '_') {
            upper = true;
            continue;
        }
        try out.append(arena, if (upper) std.ascii.toUpper(byte) else byte);
        upper = false;
    }
    return out.items;
}

fn camel(arena: std.mem.Allocator, snake: []const u8) ![]const u8 {
    const name = try pascal(arena, snake);
    const out = try arena.dupe(u8, name);
    out[0] = std.ascii.toLower(out[0]);
    return out;
}

/// Writes `shape` with an example value in each hole: the hole's default,
/// or the JSON `examples` gives for its index, as `.{ index, json }` pairs.
/// A third entry overrides the example when optional members are absent.
pub fn writeExample(out: *std.Io.Writer, comptime shape: anytype, comptime examples: anytype) !void {
    return writeExampleWith(out, shape, examples, true);
}

fn writeExampleWith(out: *std.Io.Writer, comptime shape: anytype, comptime examples: anytype, optional: bool) anyerror!void {
    return writeExampleFrom(out, shape, examples, optional, 0);
}

fn holeCount(comptime shape: anytype) usize {
    comptime var count = 0;
    inline for (shape) |part| {
        if (comptime isOptional(part)) {
            count += comptime holeCount(part.optional_shape);
        } else if (comptime !isLiteral(part)) count += 1;
    }
    return count;
}

fn writeExampleFrom(out: *std.Io.Writer, comptime shape: anytype, comptime examples: anytype, optional: bool, comptime first_hole: usize) anyerror!void {
    comptime var hole_index = first_hole;
    inline for (shape, 0..) |part, index| {
        if (comptime isOptional(part)) {
            if (optional) try writeExampleFrom(out, part.optional_shape, examples, optional, hole_index);
            hole_index += comptime holeCount(part.optional_shape);
        } else if (comptime isLiteral(part)) {
            try out.writeAll(part);
        } else {
            const override = comptime blk: {
                for (examples) |pair| if (pair[0] == hole_index) break :blk pair;
                break :blk .{ 0, @as(?[]const u8, null) };
            };
            hole_index += 1;
            const json: ?[]const u8 = if (comptime override.len == 3) (if (optional) override[1] else override[2]) else override[1];
            if (json) |value| {
                try out.writeAll(value);
            } else if (comptime @TypeOf(part) == type) {
                if (@hasDecl(part, "openapi_example")) {
                    try part.openapi_example(out);
                } else try writeExampleWith(out, part.openapi_shape, .{}, optional);
            } else try writeHoleExample(out, part, comptime isQuoted(shape, index));
        }
    }
}

fn writeHoleExample(out: *std.Io.Writer, comptime hole: Hole, comptime quoted: bool) !void {
    if (quoted) return switch (hole) {
        .decimal => out.writeAll("1"),
        .tag => |T| out.writeAll(@tagName(std.meta.tags(T)[0])),
        .text => out.writeAll("x"),
        .hex => |bytes| out.writeAll(&@as([2 * bytes]u8, @splat('0'))),
        else => @compileError("a quoted hole renders text"),
    };
    return switch (hole) {
        .boolean => out.writeAll("false"),
        .optional_id => out.writeAll("\"1\""),
        .tag_set => |T| out.print("[\"{s}\"]", .{@tagName(std.meta.tags(T)[0])}),
        .optional_tag => |T| out.print("\"{s}\"", .{@tagName(std.meta.tags(T)[0])}),
        .string => out.writeAll("\"s\""),
        .optional_string, .optional_json => out.writeAll("null"),
        else => @compileError("no example for this hole: " ++ @tagName(hole)),
    };
}

/// The document as `openapi.json` holds it: two-space indented, with a
/// final newline.
pub fn render(gpa: std.mem.Allocator) ![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var document: Document = .init(arena.allocator());
    const value = try document.build();
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

test "openapi.json is what the wire types emit" {
    const emitted = try render(std.testing.allocator);
    defer std.testing.allocator.free(emitted);
    const checked_in = @embedFile("openapi.json");
    if (!std.mem.eql(u8, emitted, checked_in)) {
        std.debug.print("openapi.json is stale: run `zig build openapi` and commit it.\n", .{});
        return error.StaleOpenApi;
    }
}

test "openapi requests use one object except exclusive targets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var document: Document = .init(arena.allocator());
    _ = try document.build();
    for (routes) |route| {
        const name = try std.fmt.allocPrint(arena.allocator(), "{s}Request", .{try pascal(arena.allocator(), @tagName(route.kind))});
        const schema = document.schemas.get(name).?.object;
        switch (route.kind) {
            .inspect_session, .skill_suggestions => try std.testing.expect(schema.contains("anyOf")),
            else => {
                try std.testing.expectEqual(@as(usize, 1), route.variants.len);
                try std.testing.expectEqualStrings("object", schema.get("type").?.string);
                try std.testing.expect(!schema.contains("anyOf"));
            },
        }
    }
    const configure = document.schemas.get("ConfigureRequest").?.object;
    for ([_][]const u8{ "reload_skills", "require_model", "preset" }) |optional| {
        try std.testing.expect(configure.get("properties").?.object.contains(optional));
        for (configure.get("required").?.array.items) |required| try std.testing.expect(!std.mem.eql(u8, optional, required.string));
    }
}

test "openapi requests parse with all or no optional members in any order" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: Document = .init(allocator);
    var prng = std.Random.DefaultPrng.init(0x727569);
    for (&routes) |*route| {
        for (route.variants, 0..) |each, index| {
            const schema = try each.schema(&document);
            for ([_]bool{ true, false }) |optional| {
                var body: std.Io.Writer.Allocating = .init(allocator);
                try each.example(&body.writer, optional);
                const json = try std.json.parseFromSliceLeaky(Value, allocator, body.written(), .{});
                // Independently check coverage, so accidentally skipping a marker
                // cannot silently turn the all-members example into a subset.
                const expected = if (optional) schema.object.get("properties").?.object.count() else schema.object.get("required").?.array.items.len;
                try std.testing.expectEqual(expected, json.object.count());
                try std.testing.expect(conforms(document.schemas, schema, json));
                try parseRequestExample(route, index, body.written(), root[0..root_len]);

                const order = try allocator.alloc(usize, json.object.count());
                for (order, 0..) |*slot, position| slot.* = position;
                prng.random().shuffle(usize, order);
                var unchanged = true;
                for (order, 0..) |slot, position| unchanged = unchanged and slot == position;
                if (unchanged and order.len > 1) std.mem.swap(usize, &order[0], &order[order.len - 1]);
                var shuffled: std.Io.Writer.Allocating = .init(allocator);
                try shuffled.writer.writeByte('{');
                for (order, 0..) |slot, position| {
                    if (position != 0) try shuffled.writer.writeByte(',');
                    try std.json.Stringify.value(json.object.keys()[slot], .{}, &shuffled.writer);
                    try shuffled.writer.writeByte(':');
                    try std.json.Stringify.value(json.object.values()[slot], .{}, &shuffled.writer);
                }
                try shuffled.writer.writeByte('}');
                try parseRequestExample(route, index, shuffled.written(), root[0..root_len]);
            }
        }
    }
}

fn parseRequestExample(route: *const Route, index: usize, bytes: []const u8, scratch_path: []const u8) !void {
    const io = std.testing.io;
    var used = std.atomic.Value(u64).init(0);
    var retained: ?@import("named_scratch.zig").Owner = null;
    var ingress: wire_request.Ingress = undefined;
    ingress.init(std.testing.allocator, .{
        .io = io,
        .content_length = bytes.len,
        .scratch_path = scratch_path,
        .request_number = 1,
        .retained_scratch = &retained,
        .scratch_budget = .{ .used = &used, .limit = 1024 * 1024 },
        .expected_kind = route.kind,
    });
    defer ingress.deinit();
    ingress.feed(bytes) catch |err| return report(route, index, bytes, err);
    const request = ingress.finish() catch |err| return report(route, index, bytes, err);
    try std.testing.expectEqual(route.kind, std.meta.activeTag(request.*));
    try request.removeTemporaryContent(io);
}

/// Materializes a derived path (named entries use a valid representative) so
/// the full document, not just a disconnected leaf schema, reaches both doors.
fn settingsSample(d: *Document, pattern: []const u8, value: Value) !Value {
    const dot = std.mem.indexOfScalar(u8, pattern, '.');
    const key = pattern[0 .. dot orelse pattern.len];
    var fields: ObjectMap = .empty;
    try fields.put(d.arena, if (std.mem.eql(u8, key, "*")) "sample" else key, if (dot) |at| try settingsSample(d, pattern[at + 1 ..], value) else value);
    return .{ .object = fields };
}

fn checkSettingsPreset(gpa: std.mem.Allocator, spec: ObjectMap) error{OutOfMemory}!?[]const u8 {
    const configuration = try gpa.create(wire_request.Configuration);
    defer gpa.destroy(configuration);
    configuration.* = .{};
    return switch (try core_tools.parseAgentSpec(gpa, spec, configuration)) {
        .accepted => null,
        .rejected => |reason| reason,
    };
}

fn applySettingsSample(d: *Document, pattern: []const u8, value: Value, accepted: bool) !void {
    const sample = if (pattern.len == 0) value else try settingsSample(d, pattern, value);
    const schema = d.schemas.get("HostSettings").?;
    const text = try std.json.Stringify.valueAlloc(d.arena, sample, .{});
    errdefer std.debug.print("settings schema witness {s}: {s}\n", .{ pattern, text });
    try std.testing.expectEqual(accepted, conforms(d.schemas, schema, sample));
    const settings = try std.testing.allocator.create(host_settings.Settings);
    defer std.testing.allocator.destroy(settings);
    settings.* = .{};
    defer settings.deinit();
    var failure: start_report.Failure = undefined;
    if (accepted) {
        try host_settings.apply(settings, d.arena, text, .pipe, checkSettingsPreset, &failure);
        var output: std.Io.Writer.Allocating = .init(d.arena);
        try host_settings.write(settings, &output.writer);
        const written = try std.json.parseFromSliceLeaky(Value, d.arena, output.written(), .{ .parse_numbers = false });
        try std.testing.expect(conforms(d.schemas, schema, written));
    } else {
        try std.testing.expectError(error.SettingsInvalid, host_settings.apply(settings, d.arena, text, .pipe, checkSettingsPreset, &failure));
    }
}

test "HostSettings schema derives every leaf and closed container from settings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var document: Document = .init(arena.allocator());
    _ = try document.build();
    var visitor: SettingsSchema = .{ .document = &document };
    try host_settings.schema(&visitor);
    _ = try visitor.finish();
    try std.testing.expectEqual(host_settings.groups.len, visitor.groups.items.len);
    for (host_settings.leaves) |leaf| {
        const sample = try std.json.parseFromSliceLeaky(Value, document.arena, leaf.sample_json, .{});
        try applySettingsSample(&document, leaf.pattern, sample, true);
        try std.testing.expect(visitor.values.contains(leaf.pattern));
        if (leaf.json_schema.min) |minimum| {
            try applySettingsSample(&document, leaf.pattern, try document.unsigned(minimum), true);
            if (minimum > 0) try applySettingsSample(&document, leaf.pattern, try document.unsigned(minimum - 1), false);
        }
        if (leaf.json_schema.max) |maximum| {
            try applySettingsSample(&document, leaf.pattern, try document.unsigned(maximum), true);
            const over = Value{ .number_string = try std.fmt.allocPrint(document.arena, "{d}", .{@as(u128, maximum) + 1}) };
            try applySettingsSample(&document, leaf.pattern, over, false);
        }
    }
    for (host_settings.groups) |group| {
        if (group.kind == .named) {
            const child = if (group.name_format.? == .preset) sample: {
                const pattern = try std.fmt.allocPrint(document.arena, "{s}.*", .{group.pattern});
                for (host_settings.leaves) |leaf| if (std.mem.eql(u8, leaf.pattern, pattern))
                    break :sample try std.json.parseFromSliceLeaky(Value, document.arena, leaf.sample_json, .{});
                return error.MissingSettingsSample;
            } else try document.object(.{});
            for ([_][]const u8{ "", "bad.name", "sample\n" }) |name| {
                var entries: ObjectMap = .empty;
                try entries.put(document.arena, name, child);
                try applySettingsSample(&document, group.pattern, .{ .object = entries }, false);
            }
            var entries: ObjectMap = .empty;
            for (0..group.max_entries.? + 1) |index| try entries.put(document.arena, try std.fmt.allocPrint(document.arena, "entry{d}", .{index}), child);
            try applySettingsSample(&document, group.pattern, .{ .object = entries }, false);
        } else {
            var unknown: ObjectMap = .empty;
            try unknown.put(document.arena, "unknown", .{ .bool = true });
            try applySettingsSample(&document, group.pattern, .{ .object = unknown }, false);
            if (group.kind == .one_adapter) {
                try applySettingsSample(&document, group.pattern, try document.object(.{}), false);
                var adapters: ObjectMap = .empty;
                for (group.keys) |name| try adapters.put(document.arena, name, try document.object(.{}));
                if (group.keys.len > 1) try applySettingsSample(&document, group.pattern, .{ .object = adapters }, false);
            }
        }
    }
}

test "HostSettings schema preserves OS bytes and exactly one secret source" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var document: Document = .init(arena.allocator());
    _ = try document.build();
    for (host_settings.leaves) |leaf| {
        if (leaf.json_schema.hex_object != null) {
            const schema = try document.settingsLeaf(leaf);
            try std.testing.expectEqualStrings("bytes", schema.object.get("x-rui-kind").?.string);
            const bytes_schema = schema.object.get("anyOf").?.array.items[0];
            const text_schema = bytes_schema.object.get("oneOf").?.array.items[0];
            const hex_schema = bytes_schema.object.get("oneOf").?.array.items[1].object.get("properties").?.object.get("hex").?;
            if (leaf.json_schema.native_path_limit) {
                try std.testing.expect(schema.object.get("x-rui-native-path-limit").?.bool);
                try std.testing.expect(!text_schema.object.contains("maxLength"));
                try std.testing.expect(!hex_schema.object.contains("maxLength"));
            } else {
                try std.testing.expect(!schema.object.contains("x-rui-native-path-limit"));
                try std.testing.expectEqual(@as(f128, @floatFromInt(leaf.json_schema.max_bytes.?)), numeric(text_schema.object.get("maxLength").?));
                try std.testing.expectEqual(@as(f128, @floatFromInt(leaf.json_schema.hex_object.?.max_length)), numeric(hex_schema.object.get("maxLength").?));
            }
            for ([_][]const u8{ "\"/tmp/example\"", "{\"hex\":\"2f746d702fff\"}" }) |text| {
                const value = try std.json.parseFromSliceLeaky(Value, document.arena, text, .{});
                try applySettingsSample(&document, leaf.pattern, value, true);
            }
            for ([_][]const u8{ "{\"hex\":\"f\"}", "{\"hex\":\"FF\"}", "{\"hex\":\"ff\\n\"}", "{\"hex\":\"2f\",\"extra\":true}", "{}" }) |text| {
                const value = try std.json.parseFromSliceLeaky(Value, document.arena, text, .{});
                try applySettingsSample(&document, leaf.pattern, value, false);
            }
        }
        if (!leaf.secret) continue;
        const secret_schema = try document.settingsLeaf(leaf);
        try std.testing.expectEqualStrings("secret", secret_schema.object.get("x-rui-kind").?.string);
        const sources = secret_schema.object.get("anyOf").?.array.items[0].object.get("oneOf").?.array.items;
        for (sources) |source| {
            const properties = source.object.get("properties").?.object;
            if (properties.get("file")) |file| try std.testing.expect(file.object.get("x-rui-native-path-limit").?.bool);
            if (properties.get("env")) |env| {
                const text = env.object.get("oneOf").?.array.items[0];
                try std.testing.expectEqual(@as(f128, @floatFromInt(leaf.json_schema.source_env_max_bytes.?)), numeric(text.object.get("maxLength").?));
            }
        }
        for ([_][]const u8{
            "{\"env\":\"TOKEN\"}",                   "{\"env\":{\"hex\":\"544fff\"}}", "{\"file\":\"/tmp/key\"}",
            "{\"file\":{\"hex\":\"2f746d702fff\"}}", "{\"owner\":true}",               "null",
        }) |text| {
            const value = try std.json.parseFromSliceLeaky(Value, document.arena, text, .{});
            try applySettingsSample(&document, leaf.pattern, value, true);
        }
        const literal = if (std.mem.eql(u8, leaf.json_schema.format.?, "mysql-login-source"))
            "{\"value\":\"mysql://user:password@localhost/database\"}"
        else
            "{\"value\":\"secret-example\"}";
        try applySettingsSample(&document, leaf.pattern, try std.json.parseFromSliceLeaky(Value, document.arena, literal, .{}), true);
        for ([_][]const u8{ "{}", "{\"owner\":false}", "{\"value\":\"key\",\"env\":\"TOKEN\"}", "{\"env\":{\"hex\":\"ff\",\"extra\":true}}" }) |text| {
            const value = try std.json.parseFromSliceLeaky(Value, document.arena, text, .{});
            try applySettingsSample(&document, leaf.pattern, value, false);
        }
    }
    inline for (std.meta.tags(start_report.StartError)) |code| {
        const line = try std.json.Stringify.valueAlloc(document.arena, .{ .rui_start_error = .{ .code = code, .message = "refused" } }, .{});
        const value = try std.json.parseFromSliceLeaky(Value, document.arena, line, .{});
        try std.testing.expect(conforms(document.schemas, document.schemas.get("StartError").?, value));
    }
}

fn report(route: *const Route, index: usize, bytes: []const u8, err: anyerror) anyerror {
    std.debug.print("{s} variant {d} refused with {s}: {s}\n", .{ route.path, index, @errorName(err), bytes });
    return err;
}

/// Checks `json` against `schema`, resolving references in `schemas`: the
/// subset of JSON Schema this document uses.
fn conforms(schemas: ObjectMap, schema: Value, json: Value) bool {
    if (schema == .bool) return schema.bool;
    const rules = schema.object;
    if (rules.get("$ref")) |target| {
        const name = target.string["#/components/schemas/".len..];
        return conforms(schemas, schemas.get(name).?, json);
    }
    if (rules.get("oneOf")) |alternatives| {
        var count: usize = 0;
        for (alternatives.array.items) |alternative| if (conforms(schemas, alternative, json)) {
            count += 1;
        };
        if (count != 1) return false;
    }
    if (rules.get("anyOf")) |alternatives| {
        for (alternatives.array.items) |alternative| if (conforms(schemas, alternative, json)) return true;
        return false;
    }
    if (rules.get("const")) |expected| return equal(expected, json);
    if (rules.get("enum")) |names| {
        for (names.array.items) |name| if (equal(name, json)) return true;
        return false;
    }
    // JSON Schema patterns constrain strings even when no explicit type is present
    // (for example propertyNames, whose instance is always a string).
    if (json == .string) if (rules.get("pattern")) |pattern| if (!matches(pattern.string, json.string)) return false;
    const type_rule = rules.get("type") orelse return true;
    if (type_rule == .array) {
        for (type_rule.array.items) |kind| if (conformsKind(schemas, rules, kind.string, json)) return true;
        return false;
    }
    return conformsKind(schemas, rules, type_rule.string, json);
}

fn conformsKind(schemas: ObjectMap, rules: ObjectMap, kind: []const u8, json: Value) bool {
    if (std.mem.eql(u8, kind, "integer")) {
        if (json != .integer and json != .number_string) return false;
        const number = numeric(json);
        if (rules.get("minimum")) |minimum| if (number < numeric(minimum)) return false;
        if (rules.get("maximum")) |maximum| if (number > numeric(maximum)) return false;
        return true;
    }
    if (std.mem.eql(u8, kind, "null")) return json == .null;
    if (std.mem.eql(u8, kind, "boolean")) return json == .bool;
    if (std.mem.eql(u8, kind, "string")) {
        if (json != .string) return false;
        if (rules.get("maxLength")) |limit| if (@as(f128, @floatFromInt(std.unicode.utf8CountCodepoints(json.string) catch return false)) > numeric(limit)) return false;
        return true;
    }
    if (std.mem.eql(u8, kind, "array")) {
        if (json != .array) return false;
        if (rules.get("maxItems")) |limit| if (@as(f128, @floatFromInt(json.array.items.len)) > numeric(limit)) return false;
        if (rules.get("prefixItems")) |prefix| {
            if (json.array.items.len != prefix.array.items.len) return false;
            for (prefix.array.items, json.array.items) |item_schema, item| if (!conforms(schemas, item_schema, item)) return false;
            return true;
        }
        if (rules.get("items")) |item_schema| for (json.array.items) |item| if (!conforms(schemas, item_schema, item)) return false;
        return true;
    }
    if (std.mem.eql(u8, kind, "object")) {
        if (json != .object) return false;
        if (rules.get("maxProperties")) |limit| if (@as(f128, @floatFromInt(json.object.count())) > numeric(limit)) return false;
        if (rules.get("minProperties")) |limit| if (@as(f128, @floatFromInt(json.object.count())) < numeric(limit)) return false;
        if (rules.get("propertyNames")) |name_schema| for (json.object.keys()) |name| if (!conforms(schemas, name_schema, .{ .string = name })) return false;
        const properties = if (rules.get("properties")) |props| props.object else ObjectMap.empty;
        for (json.object.keys(), json.object.values()) |name, value| {
            const property = properties.get(name) orelse rules.get("additionalProperties") orelse continue;
            if (!conforms(schemas, property, value)) return false;
        }
        if (rules.get("required")) |required| for (required.array.items) |name| if (!json.object.contains(name.string)) return false;
        return true;
    }
    return false;
}

fn numeric(value: Value) f128 {
    return switch (value) {
        .integer => |number| @floatFromInt(number),
        .float => |number| @floatCast(number),
        .number_string => |text| std.fmt.parseFloat(f128, text) catch unreachable,
        else => unreachable,
    };
}

fn equal(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |value| b == .bool and b.bool == value,
        .integer => |value| b == .integer and b.integer == value,
        .string => |value| b == .string and std.mem.eql(u8, b.string, value),
        else => false,
    };
}

/// The pattern forms this document writes: decimal, tool names and fixed-length hex.
fn matches(pattern: []const u8, text: []const u8) bool {
    if (std.mem.eql(u8, pattern, "^(0|[1-9][0-9]*)$")) {
        if (text.len == 0 or (text.len > 1 and text[0] == '0')) return false;
        for (text) |byte| if (!std.ascii.isDigit(byte)) return false;
        return true;
    }
    if (std.mem.eql(u8, pattern, host_settings.Schema.os_bytes_pattern)) {
        if (text.len % 2 != 0) return false;
        for (text) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
        return true;
    }
    const lower_name = std.mem.startsWith(u8, pattern, "^[a-z0-9_-]{1,");
    if (lower_name or std.mem.startsWith(u8, pattern, "^[A-Za-z0-9_-]{1,")) {
        const begin = std.mem.indexOfScalar(u8, pattern, ',').? + 1;
        const end = std.mem.indexOfScalarPos(u8, pattern, begin, '}').?;
        const maximum = std.fmt.parseInt(usize, pattern[begin..end], 10) catch unreachable;
        if (text.len == 0 or text.len > maximum) return false;
        for (text) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
            if (lower_name and std.ascii.isUpper(byte)) return false;
        }
        return true;
    }
    const length = std.fmt.parseInt(usize, pattern["^[0-9a-f]{".len .. pattern.len - "}$".len], 10) catch unreachable;
    if (text.len != length) return false;
    for (text) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

test "replies the Host renders conform to their schemas" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var document: Document = .init(arena.allocator());
    const built = try document.build();
    const schemas = built.object.get("components").?.object.get("schemas").?.object;
    const Case = struct {
        fn check(all: ObjectMap, name: []const u8, text: []const u8, a: std.mem.Allocator) !void {
            const json = try std.json.parseFromSliceLeaky(Value, a, text, .{});
            if (!conforms(all, all.get(name).?, json)) {
                std.debug.print("{s} does not conform: {s}\n", .{ name, text });
                return error.Nonconforming;
            }
        }
        schemas: ObjectMap,
        allocator: std.mem.Allocator,

        pub fn report(self: @This(), bytes: []const u8) !void {
            try check(self.schemas, "InspectSessionReply", bytes, self.allocator);
        }
    };
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);

    // Render the real request refusal, including its advisory server names.
    const reply = @import("command_reply.zig");
    const host_reply = @import("host_reply.zig");
    var configured: reply.ConfigureReply = .{ .rejected = .{ .replayed = false, .code = .mcp_server_unavailable } };
    var host_tool_set = @import("tools.zig").built_in_tool_set;
    host_tool_set.configured_servers = &.{"notes"};
    configured.rejected.message = host_tool_set.missingTool("lookup");
    try host_reply.renderConfigureReply(.{ .writer = &out.writer }, "", configured);
    try Case.check(schemas, "ConfigureReply", out.written(), a);
    out.clearRetainingCapacity();
    const message: reply.MessageReply = .{ .rejected = .{ .replayed = false, .code = .mcp_server_unavailable, .message = configured.rejected.message, .content = .{ .length = 4, .digest = protocol.contentDigest("task") } } };
    try host_reply.renderMessageReply(.{ .writer = &out.writer }, "", message);
    try Case.check(schemas, "MessageReply", out.written(), a);
    out.clearRetainingCapacity();

    // The model list is written in code, not as a shape.
    const ids = "gpt-6.1-sol\nmy\"model\n";
    try out.writer.writeAll(protocol.model_list_reply.head);
    try model_list.writeProviders(&out.writer, model_catalog.shipped, &.{
        .{ .provider = .codex, .list = .catalog },
        .{ .provider = .openai, .list = .{ .live = .{ .bytes = ids } } },
    });
    try out.writer.writeAll(protocol.model_list_reply.tail);
    try Case.check(schemas, "ModelListReply", out.written(), a);

    out.clearRetainingCapacity();
    var facts: protocol.ActivityFacts = .{ .end = 9, .count = 2 };
    facts.items[0] = .{ .position = 1, .at = 7, .value = .{ .admission = .{ .admission = 1, .key = .{}, .turn = null, .state = .queued, .content = .{ .length = 3, .digest = @splat(1) }, .admitted_at = 7 } } };
    facts.items[1] = .{ .position = 2, .ordinal = 1, .at = 8, .value = .{ .turn_ended = .{ .session = .{ .bytes = "k7m2qx".*, .len = 6 }, .turn = 1, .operation = 1, .ending = @fromBackingInt(@intCast(0)), .code = .{}, .content = null } } };
    facts.work.work.state = .{ .failed = .{ .since = 3, .code = .{}, .resets_at = 4 } };
    try activity_reply.writePage(&out.writer, &facts);
    try Case.check(schemas, "ActivityPageReply", out.written(), a);

    out.clearRetainingCapacity();
    const row: protocol.SessionRow = .{ .tools = try .of(&.{"bash"}), .label = .{} };
    try protocol.writeShape(&out.writer, protocol.session_list_reply.head, .{});
    try row.writeJson(&out.writer);
    try protocol.writeShape(&out.writer, protocol.session_list_reply.last_tail, .{ protocol.ListDelta.full, "x", true });
    try Case.check(schemas, "ListSessionsReply", out.written(), a);
    out.clearRetainingCapacity();
    try protocol.writeShape(&out.writer, protocol.session_list_reply.head ++ protocol.session_list_reply.unchanged_tail, .{ protocol.ListDelta.not_modified, "x" });
    try Case.check(schemas, "ListSessionsReply", out.written(), a);

    // These are the Store's real streaming reports, not schema examples:
    // an added hand-written field must fail additionalProperties here.
    try store.checkSessionReportsForTesting(Case{ .schemas = schemas, .allocator = a });
}

test "Host information has one schema with an omittable bounded diagnostic" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var document: Document = .init(arena.allocator());
    _ = try document.build();
    const schema = document.schemas.get("HostInfoReply").?;
    try std.testing.expect(!schema.object.contains("anyOf"));
    try std.testing.expectEqualStrings("object", schema.object.get("type").?.string);
    const properties = schema.object.get("properties").?.object;
    const diagnostic = properties.get("innodb_doublewrite").?.object;
    try std.testing.expectEqualStrings("string", diagnostic.get("type").?.string);
    try std.testing.expectEqual(@as(i64, 32), diagnostic.get("maxLength").?.integer);
    try std.testing.expectEqual(@as(i64, protocol.max_store_bytes), properties.get("store").?.object.get("maxLength").?.integer);
    for (schema.object.get("required").?.array.items) |required|
        try std.testing.expect(!std.mem.eql(u8, "innodb_doublewrite", required.string));

    // One schema accepts both Host-emitted forms, and the diagnostic's
    // presence does not narrow the selector to a MySQL id.
    const host_reply = @import("host_reply.zig");
    const stores = [_][]const u8{ "/sqlite", "0123456789abcdef0123456789abcdef", &@as([protocol.max_store_bytes]u8, @splat('s')) };
    for (stores) |selector| {
        for ([_]?[]const u8{ null, "OFF", &@as([32]u8, @splat(1)) }) |doublewrite| {
            var response: protocol.ResponseBuffer = .{};
            try response.render(host_reply.renderHostInfo, .{host_reply.HostInfo{
                .store = selector,
                .instance = @splat(1),
                .active_capacity = 2,
                .intake_capacity = 100,
                .descriptor_soft_limit = 1024,
                .started_at = 1792918800,
                .custody_occupied = 0,
                .paused = false,
                .routes = protocol.routesAll(.unserved),
                .doublewrite = doublewrite,
            }});
            var json = try std.json.parseFromSliceLeaky(Value, arena.allocator(), response.slice(), .{});
            try std.testing.expect(conforms(document.schemas, schema, json));
            try std.testing.expectEqual(doublewrite != null, json.object.contains("innodb_doublewrite"));
            // Omission is not nullability, and the string has an actual bound.
            try json.object.put(arena.allocator(), "innodb_doublewrite", .null);
            try std.testing.expect(!conforms(document.schemas, schema, json));
            try json.object.put(arena.allocator(), "innodb_doublewrite", .{ .string = &@as([33]u8, @splat('x')) });
            try std.testing.expect(!conforms(document.schemas, schema, json));
        }
    }
}

test "Message observation schema requires Host state and bounds recovery" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: Document = .init(allocator);
    const built = try document.build();
    const schemas = built.object.get("components").?.object.get("schemas").?.object;
    const schema = schemas.get("ObserveCommandReply").?;
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"delta\":\"full\",\"since\":null,\"observation\":{";
    const head = prefix ++ "\"status\":\"accepted\",\"kind\":\"message\",\"target\":\"k7m2qx\",";
    const input = "\"input\":{\"type\":\"text\",\"bytes\":\"1\",\"sha256\":\"" ++ "0000000000000000000000000000000000000000000000000000000000000000" ++ "\"},\"queue\":{\"admission\":\"1\",\"admitted_at\":\"2\"}";
    const binding = ",\"binding\":{\"turn\":\"3\",\"operation\":\"4\",\"attempt\":\"1\"}";
    const recovery = ",\"recovery\":{\"unknown_outcomes\":[{\"action\":\"5\",\"operation\":\"4\",\"call\":\"0\",\"description\":null,\"at\":\"6\"}],\"more\":false}";
    const cases = .{
        prefix ++ "\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"k7m2qx\",\"code\":\"unknown_session\",\"state\":\"rejected\"}}",
        head ++ "\"state\":\"queued\"," ++ input ++ ",\"work\":{\"state\":{\"kind\":\"pending\",\"since\":\"2\"},\"first_action\":null}}}",
        head ++ "\"state\":\"waiting_for_permission\"," ++ input ++ ",\"work\":{\"state\":{\"kind\":\"approval\",\"since\":\"2\"},\"first_action\":\"5\"}}}",
        head ++ "\"state\":\"processing\"," ++ input ++ binding ++ ",\"work\":{\"state\":{\"kind\":\"working\",\"since\":\"2\"},\"first_action\":null}" ++ recovery ++ "}}",
        head ++ "\"state\":\"completed\"," ++ input ++ binding ++ ",\"result\":{\"status\":\"completed\",\"text\":{\"type\":\"text\",\"bytes\":\"0\",\"sha256\":\"" ++ "0000000000000000000000000000000000000000000000000000000000000000" ++ "\"}}" ++ recovery ++ "}}",
        head ++ "\"state\":\"failed\"," ++ input ++ binding ++ ",\"result\":{\"status\":\"failed\",\"code\":\"failed\"}" ++ recovery ++ "}}",
        head ++ "\"state\":\"cancelled\"," ++ input ++ binding ++ ",\"result\":{\"status\":\"cancelled\",\"code\":\"cancelled\"}" ++ recovery ++ "}}",
    };
    inline for (cases) |text| {
        const value = try std.json.parseFromSliceLeaky(Value, allocator, text, .{});
        try std.testing.expect(conforms(schemas, schema, value));
    }
    const missing_state = try std.json.parseFromSliceLeaky(Value, allocator, prefix ++ "\"status\":\"rejected\",\"kind\":\"message\",\"target\":\"k7m2qx\"}}", .{});
    try std.testing.expect(!conforms(schemas, schema, missing_state));

    const calls: [protocol.message_recovery_limit]protocol.MessageUnknownOutcome = @splat(.{ .action_id = 1, .operation_id = 2, .call = 0, .at = 3 });
    var out: std.Io.Writer.Allocating = .init(allocator);
    try (protocol.MessageRecoveryJson{ .calls = &calls, .more = true }).writeJson(&out.writer);
    var value = try std.json.parseFromSliceLeaky(Value, allocator, out.written(), .{});
    const recovery_schema = schemas.get("MessageRecoveryJson").?;
    try std.testing.expect(conforms(schemas, recovery_schema, value));
    const outcomes = &value.object.getPtr("unknown_outcomes").?.array;
    try outcomes.append(outcomes.items[0]);
    try std.testing.expect(!conforms(schemas, recovery_schema, value));
}

test "statuses, media types and required headers match what the Host sends" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var document: Document = .init(arena.allocator());
    const built = try document.build();
    const paths = built.object.get("paths").?.object;
    const mutations = [_]protocol.CommandKind{ .configure, .message, .session_stop, .session_archive, .model_interruption, .permission_decision };
    for (mutations) |kind| {
        const responses = paths.get(kind.route()).?.object.get("post").?.object.get("responses").?.object;
        try std.testing.expect(responses.contains("409"));
        try std.testing.expect(responses.get("200").?.object.get("content").?.object.contains("application/json"));
    }
    const media = [_]struct { path: []const u8, type: []const u8 }{
        .{ .path = "/v1/read-result", .type = "text/plain" },
        .{ .path = "/v1/read-action-call-id", .type = "text/plain" },
        .{ .path = "/v1/read-action-arguments", .type = "text/plain" },
        .{ .path = "/v1/conversation-content", .type = "application/octet-stream" },
        .{ .path = "/v1/activity-content", .type = "application/octet-stream" },
        .{ .path = "/v1/inspect-session", .type = "application/json" },
        .{ .path = "/v1/inspect-session", .type = "application/octet-stream" },
    };
    for (media) |each| {
        const responses = paths.get(each.path).?.object.get("post").?.object.get("responses").?.object;
        try std.testing.expect(responses.get("200").?.object.get("content").?.object.contains(each.type));
    }
    const stop = paths.get("/v1/control/host-stop").?.object.get("post").?.object.get("parameters").?.array;
    var required = false;
    for (stop.items) |parameter| {
        if (std.mem.endsWith(u8, parameter.object.get("$ref").?.string, "/HostInstanceRequired")) required = true;
    }
    try std.testing.expect(required);
}

const ActivitySearchItem = struct {
    pub const openapi_shape = activity_reply.SearchMatchJson.head ++ .{ ListOf(activity_reply.SearchHitJson), "]}" };
};

test "Command observation schema requires full metadata or a token-only repeat" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: Document = .init(allocator);
    const built = try document.build();
    const schemas = built.object.get("components").?.object.get("schemas").?.object;
    const schema = schemas.get("ObserveCommandReply").?;
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\"";
    const cases = .{
        .{ prefix ++ ",\"delta\":\"full\",\"since\":null,\"observation\":{\"status\":\"absent\"}}", true },
        .{ prefix ++ ",\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.42.k7m2qx\"}", true },
        .{ prefix ++ ",\"observation\":{\"status\":\"absent\"}}", false },
        .{ prefix ++ ",\"delta\":\"not_modified\",\"since\":null}", false },
        .{ prefix ++ ",\"delta\":\"not_modified\",\"since\":\"token\",\"observation\":{\"status\":\"absent\"}}", false },
    };
    inline for (cases) |case| {
        const value = try std.json.parseFromSliceLeaky(Value, allocator, case[0], .{});
        try std.testing.expectEqual(case[1], conforms(schemas, schema, value));
    }
}

test "Activity schema distinguishes full pages and token-only repeats" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: Document = .init(allocator);
    const built = try document.build();
    const schemas = built.object.get("components").?.object.get("schemas").?.object;
    const schema = schemas.get("ActivityPageReply").?;
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"activity_page\"";
    const cases = .{
        .{ prefix ++ ",\"delta\":\"not_modified\",\"since\":\"abababababababababababababababab.42.k7m2qx\"}", true },
        .{ prefix ++ ",\"delta\":\"not_modified\",\"since\":null}", false },
        .{ prefix ++ ",\"delta\":\"not_modified\"}", false },
        .{ prefix ++ ",\"delta\":\"full\",\"since\":null}", false },
    };
    inline for (cases) |case| {
        const value = try std.json.parseFromSliceLeaky(Value, allocator, case[0], .{});
        try std.testing.expectEqual(case[1], conforms(schemas, schema, value));
    }
}

test "Activity schema requires a nullable failed-send target without weakening other peers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: Document = .init(allocator);
    const built = try document.build();
    const schemas = built.object.get("components").?.object.get("schemas").?.object;
    const schema = schemas.get("ActivityItem").?;
    const prefix = "{\"position\":\"7\",\"ordinal\":\"0\",\"at\":\"1\",\"value\":{\"send_failed\":{\"key\":\"refused\",\"code\":\"invalid_session_reference\"";
    const cases = .{
        .{ prefix ++ ",\"target\":null}}}", true },
        .{ prefix ++ ",\"target\":{\"session\":\"absent\",\"label\":null}}}}", true },
        // NamedPeer's generated schema describes bounded wire strings, not
        // canonical ID semantics. Native JsonNamedPeer still rejects this.
        .{ prefix ++ ",\"target\":{\"session\":\"\",\"label\":null}}}}", true },
        .{ prefix ++ "}}}", false },
        .{ prefix ++ ",\"target\":{}}}}", false },
        .{ prefix ++ ",\"target\":\"\"}}}", false },
        .{ prefix ++ ",\"target\":{\"session\":\"absent\"}}}}", false },
        .{ prefix ++ ",\"target\":{\"session\":null,\"label\":null}}}}", false },
        .{ "{\"position\":\"7\",\"ordinal\":\"0\",\"at\":\"1\",\"value\":{\"sent\":{\"admission\":\"1\",\"admitted_at\":\"1\",\"target\":null,\"content\":{\"bytes\":\"0\",\"sha256\":\"" ++ "abababababababababababababababababababababababababababababababab" ++ "\"}}}}", false },
    };
    inline for (cases) |case| {
        const value = try std.json.parseFromSliceLeaky(Value, allocator, case[0], .{});
        try std.testing.expectEqual(case[1], conforms(schemas, schema, value));
    }
}

test "catalog full report schema represents turnless catalog source facts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var document: Document = .init(arena.allocator());
    const shape = try document.shapeSchema(session_report_reply.FullJson.Conversation.json_shape);
    const json = try std.json.parseFromSliceLeaky(
        Value,
        arena.allocator(),
        "{\"ordinal\":\"1\",\"position\":\"1\",\"kind\":\"settings\",\"turn\":null,\"source_admission\":null,\"source_revision\":null,\"source_catalog_position\":\"1\",\"source_skill_position\":null,\"source_operation\":null,\"content\":{\"bytes\":\"12\",\"sha256\":\"" ++ @as([64]u8, @splat('0')) ++ "\"}}",
        .{},
    );
    try std.testing.expect(conforms(document.schemas, shape, json));
}

test "model_call Activity schema requires nullable metrics and final attempt description" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: Document = .init(allocator);
    const built = try document.build();
    const schemas = built.object.get("components").?.object.get("schemas").?.object;
    const schema = schemas.get("ActivityItem").?;
    const row = "{\"position\":\"4\",\"ordinal\":\"0\",\"at\":\"7\",\"value\":{\"model_call\":{\"model\":\"requested\",\"served_model\":null,\"input_tokens\":null,\"output_tokens\":null,\"cached_tokens\":null,\"latency_ms\":\"0\",\"first_event_ms\":null,\"status\":\"cancelled\",\"attempts\":\"2\"}}}";
    const parsed = try std.json.parseFromSliceLeaky(Value, allocator, row, .{});
    try std.testing.expect(conforms(schemas, schema, parsed));
    inline for (.{ "served_model", "input_tokens", "output_tokens", "cached_tokens", "latency_ms", "first_event_ms" }) |field| {
        var missing = try std.json.parseFromSliceLeaky(Value, allocator, row, .{});
        _ = missing.object.getPtr("value").?.object.getPtr("model_call").?.object.swapRemove(field);
        try std.testing.expect(!conforms(schemas, schema, missing));
    }
    var found = false;
    for (schema.object.get("anyOf").?.array.items) |variant_schema| {
        if (variant_schema.object.get("description")) |row_description| {
            try std.testing.expect(std.mem.indexOf(u8, row_description.string, "FINAL attempt") != null);
            try std.testing.expect(std.mem.indexOf(u8, row_description.string, "first HTTP response event") != null);
            found = true;
        }
    }
    try std.testing.expect(found);
}
