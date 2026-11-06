//! The Host's wire contract as an OpenAPI 3.1 document, built from
//! protocol.zig's JSON shapes: the request shapes the client writes and the
//! reply shapes the Host writes. `zig build openapi` writes it to
//! `openapi.json`; a test fails when the checked-in file differs from what
//! this emits, and another parses a generated example of every request
//! variant with the Host's own parser. Clients in other languages are
//! generated from that file.
//!
//! A shape is a tuple of literal JSON text and `protocol.Hole`s. To turn one
//! into a schema, each hole is written as a marker string, the text is parsed
//! as JSON, and each marker becomes its hole's schema. A shape here may also
//! hold a marker type (see `ListOf`, `State`, `Content`) for the parts the
//! Host and client write in code rather than as one shape.
const std = @import("std");
const protocol = @import("protocol.zig");
const model_list = @import("model_list.zig");
const store = @import("store.zig");
const launch_frame = @import("launch_frame.zig");
const core_tools = @import("core_tools.zig");
const Hole = protocol.Hole;
const Value = std.json.Value;
const ObjectMap = std.json.ObjectMap;

/// One route: its path, its request variants, and its reply.
const Route = struct {
    path: []const u8,
    kind: protocol.Kind,
    summary: []const u8,
    /// Each a request shape; the request schema is any one of them.
    variants: []const Variant,
    reply: Reply,
    /// The reply under HTTP 409 when a retried key meets different input.
    conflict: ?Reply = null,
};

/// A request shape, kept as its two uses so `Route` stays a runtime value.
const Variant = struct {
    schema: *const fn (*Document) anyerror!Value,
    example: *const fn (*std.Io.Writer) anyerror!void,
};

fn variant(comptime shape: anytype, comptime examples: anytype) Variant {
    const S = struct {
        const value = shape;
        fn schema(d: *Document) anyerror!Value {
            return d.shapeSchema(value);
        }
        fn example(out: *std.Io.Writer) anyerror!void {
            return writeExample(out, value, examples);
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
        .reply = jsonReply(.{ protocol.host_info_reply, protocol.host_info_mysql_reply }),
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
        .variants = &.{
            variant(protocol.configure_request.head ++ .{Configuration} ++ protocol.configure_request.tail, .{}),
            variant(protocol.configure_request.head ++ .{Configuration} ++ protocol.configure_request.require_model_tail, .{}),
            variant(protocol.configure_request.head ++ .{Configuration} ++ protocol.configure_request.preset_tail, .{}),
            variant(protocol.configure_request.head ++ .{Configuration} ++ protocol.configure_request.preset_require_model_tail, .{}),
        },
        .reply = jsonReply(.{ protocol.configuration_reply.accepted, protocol.configuration_reply.rejected }),
        .conflict = jsonReply(.{protocol.configuration_reply.conflict}),
    },
    .{
        .path = protocol.CommandKind.message.route(),
        .kind = .message,
        .summary = "Sends a Message to a Session, or creates the Session when `session` is empty. Retried by its key. The body starts with the client environment, `X-Rui-Environment-Bytes` long, before the JSON.",
        .variants = &.{
            variant(protocol.message_request.head ++ protocol.message_request.text ++ .{Content} ++ protocol.message_request.tail, .{}),
            // A sending Session's address: an absolute Store path and a Session id.
            variant(protocol.message_request.sender_head ++ protocol.message_request.text ++ .{Content} ++ protocol.message_request.tail, .{ .{ 3, "\"/s\"" }, .{ 4, "\"aaaaaa\"" } }),
            // A creating Message names no Session.
            variant(protocol.message_request.head ++ protocol.message_request.configuration ++ .{MessageConfiguration} ++ protocol.message_request.text ++ .{Content} ++ protocol.message_request.tail, .{.{ 2, "\"\"" }}),
            variant(protocol.message_request.head ++ protocol.message_request.configuration ++ .{MessageConfiguration} ++ protocol.message_request.text ++ .{Content} ++ protocol.message_request.require_model_tail, .{.{ 2, "\"\"" }}),
        },
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
        .variants = &.{variant(protocol.observe_command_request, .{})},
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
            variant(protocol.inspect_session_request.current, .{}),
            variant(protocol.inspect_session_request.full, .{}),
            variant(protocol.inspect_session_request.failed_response, .{}),
        },
        .reply = .report,
    },
    .{
        .path = "/v1/list-sessions",
        .kind = .list_sessions,
        .summary = "One page of Sessions, newest first, or what changed since a token.",
        .variants = &.{
            variant(protocol.list_sessions_request, .{}),
            // A token continues from the start of the list.
            variant(protocol.list_sessions_since_request, .{ .{ 2, "0" }, .{ 3, "0" }, .{ 4, since_example } }),
            variant(protocol.list_sessions_changed_request, .{ .{ 2, "0" }, .{ 3, "0" }, .{ 4, since_example }, .{ 6, "\"aaaaaa\"" } }),
        },
        .reply = jsonReply(.{
            protocol.session_list_reply.head ++ .{ListOf(protocol.SessionRow)} ++ protocol.session_list_reply.full_tail,
            protocol.session_list_reply.head ++ .{ListOf(protocol.SessionRow)} ++ protocol.session_list_reply.changed_tail,
            protocol.session_list_reply.head ++ .{ListOf(protocol.SessionRow)} ++ protocol.session_list_reply.last_tail,
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
        .variants = &.{variant(protocol.conversation_content_request, .{})},
        .reply = .bytes,
    },
    .{
        .path = "/v1/activity-search",
        .kind = .activity_search,
        .summary = "Search public Session activity newest first with bounded snippets.",
        .variants = &.{variant(protocol.activity_search_request, .{})},
        .reply = jsonReply(.{protocol.ActivitySearchFacts.head ++ .{ListOf(ActivitySearchItem)} ++ protocol.ActivitySearchFacts.tail}),
    },
    .{
        .path = "/v1/activity-page",
        .kind = .activity_page,
        .summary = "One page of a Session's activity feed, with its work and queue at the page's boundary.",
        .variants = &.{variant(protocol.activity_page_request, .{})},
        .reply = jsonReply(.{protocol.ActivityFacts.head ++ .{ListOf(protocol.ActivityItem)} ++ protocol.ActivityFacts.tail}),
    },
    .{
        .path = "/v1/activity-content",
        .kind = .activity_content,
        .summary = "The content of one activity row.",
        .variants = &.{variant(protocol.activity_content_request, .{})},
        .reply = .bytes,
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

/// A string of any length, which the Host saves as content.
const Content = struct {
    pub fn openapi_inline(d: *Document) !Value {
        return d.object(.{ .type = Value{ .string = "string" }, .description = Value{ .string = "Text of any length, saved as content." } });
    }
    pub fn openapi_example(out: *std.Io.Writer) !void {
        try out.writeAll("\"x\"");
    }
};

/// A configuration field: left `omitted`, cleared with `null` when
/// `allow_null`, or set to `value`, a hole or marker, when it is not null.
fn State(comptime value: anytype, comptime allow_null: bool) type {
    return struct {
        const omitted = .{"{\"state\":\"omitted\"}"};
        const cleared = .{"{\"state\":\"null\"}"};
        const set = .{ "{\"state\":\"value\",\"value\":", value, "}" };

        pub fn openapi_inline(d: *Document) !Value {
            var values: [3]Value = undefined;
            var count: usize = 0;
            values[count] = try d.shapeSchema(omitted);
            count += 1;
            if (allow_null) {
                values[count] = try d.shapeSchema(cleared);
                count += 1;
            }
            if (@TypeOf(value) != @TypeOf(null)) {
                values[count] = try d.shapeSchema(set);
                count += 1;
            }
            return d.anyOf(values[0..count]);
        }
        pub fn openapi_example(out: *std.Io.Writer) !void {
            if (@TypeOf(value) == @TypeOf(null)) return writeExample(out, omitted, .{});
            return writeExample(out, set, .{});
        }
    };
}

const Tool = protocol.BuiltInTool;

/// A configure's `tools`: names the Host offers, sorted by bytes, none repeated.
const ToolNameList = struct {
    pub fn openapi_inline(d: *Document) !Value {
        return d.object(.{
            .type = Value{ .string = "array" },
            .items = try d.object(.{
                .type = Value{ .string = "string" },
                .pattern = Value{ .string = std.fmt.comptimePrint("^[A-Za-z0-9_-]{{1,{d}}}$", .{protocol.max_tool_name_bytes}) },
            }),
            .maxItems = Value{ .integer = protocol.max_tools },
            .uniqueItems = Value{ .bool = true },
            .@"x-rui-max-bytes" = Value{ .integer = protocol.max_tool_list_name_bytes },
            .description = Value{ .string = "Sorted by bytes, none repeated; the names' bytes total at most x-rui-max-bytes. Each must be a tool the Host offers." },
        });
    }
    pub fn openapi_example(out: *std.Io.Writer) !void {
        try out.print("[\"{s}\"]", .{@tagName(std.meta.tags(Tool)[0])});
    }
};

/// Fields after `output_schema` are optional to the parser, in any order;
/// the client always sends all four, in this order. Creation requires model,
/// effort, compaction trigger, tools and permission mode, and a Workspace
/// with bash (D113, D133); the schema states no `required` because an
/// addressed configure may omit every field.
fn configurationShape(comptime name: []const u8, comptime instructions: anytype, comptime output_schema: anytype) type {
    return struct {
        pub const openapi_name = name;
        pub const openapi_optional_fields = .{"loaded_tools"};
        pub const openapi_shape = .{
            "{\"workspace\":",          State(Hole{ .string = protocol.max_workspace_bytes }, false),
            ",\"provider\":",           State(Hole{ .string = protocol.max_provider_bytes }, false),
            ",\"model\":",              State(Hole{ .string = protocol.max_model_bytes }, false),
            ",\"instructions\":",       instructions,
            ",\"tools\":",              State(ToolNameList, false),
            ",\"loaded_tools\":",       State(ToolNameList, false),
            ",\"permission_mode\":",    State(Hole{ .string = 16 }, false),
            ",\"output_schema\":",      output_schema,
            ",\"compaction_trigger\":", State(Hole{ .string = 20 }, true),
            ",\"output_reservation\":", State(Hole{ .string = 20 }, true),
            ",\"reasoning_effort\":",   State(Hole{ .string = 16 }, true),
            ",\"label\":",              State(Hole{ .string = protocol.max_label_bytes }, true),
            "}",
        };
    };
}

/// A `configure` request's settings.
const Configuration = configurationShape("Configuration", State(Content, false), State(Content, true));
/// A creating Message's settings, which carry no content.
const MessageConfiguration = configurationShape("MessageConfiguration", State(null, false), State(null, true));

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
    var kinds: [std.meta.tags(protocol.CommandKind).len + 1]Value = undefined;
    kinds[0] = try d.shapeSchema(o.absent);
    inline for (comptime std.meta.tags(protocol.CommandKind), 1..) |kind, index| {
        const bodies = switch (kind) {
            .configure => .{ .{}, o.revision },
            .message => o.message_variants,
            .session_stop => .{ .{}, o.session_stop },
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
            var schema = try d.shapeSchema(T.openapi_shape);
            if (@hasDecl(T, "openapi_optional_fields")) {
                const required = &schema.object.getPtr("required").?.array;
                inline for (T.openapi_optional_fields) |optional| {
                    for (required.items, 0..) |field, index| {
                        if (std.mem.eql(u8, field.string, optional)) {
                            _ = required.orderedRemove(index);
                            break;
                        }
                    }
                }
            }
            return schema;
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
        if (T == protocol.CallActivity) return d.shapeSchema(T.head ++ .{ListOf(T.entry_shape)} ++ T.tail);
        if (T == protocol.ActivityItem) {
            const kinds = comptime std.meta.tags(protocol.ActivityItem.Kind);
            var values: [kinds.len]Value = undefined;
            inline for (kinds, 0..) |kind, index| values[index] = try d.shapeSchema(tuple(T.head(kind)) ++ @field(T.value_shapes, @tagName(kind)) ++ T.tail);
            return d.anyOf(&values);
        }
        if (T == protocol.Queued) return d.shapeSchema(T.shape);
        if (T == protocol.SessionRow) return d.shapeSchemaWith(T.json_shape, ToolNames);
        if (@hasDecl(T, "json_shape")) return d.shapeSchema(T.json_shape);
        @compileError("no wire schema for " ++ @typeName(T));
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
                    const schema = if (comptime T == launch_frame.Wire and std.mem.eql(u8, name, "presets"))
                        try d.object(.{
                            .type = Value{ .string = "object" },
                            .additionalProperties = try d.ref("AgentSpec"),
                            .maxProperties = Value{ .integer = core_tools.max_presets },
                        })
                    else
                        try d.wireSchema(Field);
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

    fn launchSchemas(d: *Document) !void {
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
        // JSON Schema defaults object properties to unconstrained values.
        // Spell that out so generated clients do not turn them into `never`.
        const output_schema = spec.object.getPtr("properties").?.object.getPtr("outputSchema").?;
        try output_schema.object.put(d.arena, "additionalProperties", .{ .bool = true });
        try d.schemas.put(d.arena, "AgentSpec", spec);
        var frame = try d.wireSchema(launch_frame.Wire);
        const properties = frame.object.getPtr("properties").?;
        try properties.object.put(d.arena, "v", try d.object(.{ .@"const" = Value{ .integer = launch_frame.version } }));
        const provider = properties.object.getPtr("provider").?.object.getPtr("properties").?;
        try provider.object.put(d.arena, "kind", try d.object(.{ .@"const" = Value{ .string = "openai_key" } }));
        try d.schemas.put(d.arena, "LaunchFrame", frame);
        try d.schemas.put(d.arena, "StartError", try d.wireSchema(struct {
            rui_start_error: struct { code: launch_frame.StartError, message: []const u8 },
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
        inline for (shape, 0..) |part, index| {
            if (comptime isLiteral(part)) {
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
        const json = try std.json.parseFromSliceLeaky(Value, d.arena, text.written(), .{});
        return d.fromJson(json, holes.items, lists.items);
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
                    const shapes = store.session_report_shapes;
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
        try d.launchSchemas();
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
pub fn writeExample(out: *std.Io.Writer, comptime shape: anytype, comptime examples: anytype) !void {
    comptime var hole_index = 0;
    inline for (shape, 0..) |part, index| {
        if (comptime isLiteral(part)) {
            try out.writeAll(part);
        } else {
            const override = comptime blk: {
                for (examples) |pair| if (pair[0] == hole_index) break :blk @as(?[]const u8, pair[1]);
                break :blk @as(?[]const u8, null);
            };
            hole_index += 1;
            if (override) |json| {
                try out.writeAll(json);
            } else if (comptime @TypeOf(part) == type) {
                if (@hasDecl(part, "openapi_example")) {
                    try part.openapi_example(out);
                } else try writeExample(out, part.openapi_shape, .{});
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

test "the Host parses a generated example of every request variant" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root);
    for (&routes) |*route| {
        for (route.variants, 0..) |each, index| {
            var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer body.deinit();
            try each.example(&body.writer);
            const bytes = body.written();
            var used = std.atomic.Value(u64).init(0);
            var retained: ?@import("named_scratch.zig").Owner = null;
            var ingress: protocol.Ingress = undefined;
            ingress.init(std.testing.allocator, .{
                .io = io,
                .content_length = bytes.len,
                .scratch_path = root[0..root_len],
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
    }
}

test "every launch Wire field parses and conforms to its component schema" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: Document = .init(allocator);
    _ = try document.build();
    const preset = try std.json.parseFromSliceLeaky(Value, allocator,
        \\{"review":{"model":"custom","effort":"low","compactAt":1000,"tools":[],"permissionMode":"ask","provider":"openai","workspace":"/tmp","instructions":"Review","outputSchema":{"type":"object"},"label":null}}
    , .{});
    const wire: launch_frame.Wire = .{
        .v = launch_frame.version,
        .store = "/tmp/store",
        .provider = .{ .kind = "openai_key", .baseUrl = "https://api.openai.com/v1", .key = "test-key", .caFile = "/tmp/ca.pem" },
        .runtimeDir = "/tmp/rui",
        .activeCapacity = 2,
        .paused = true,
        .presets = preset,
        .mcpServers = &.{.{ .name = "tools", .url = "http://127.0.0.1:1234/mcp", .bearerToken = "test-token", .callTimeoutMs = 1000 }},
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, wire, .{});
    var frame: launch_frame.Frame = .{};
    defer frame.deinit();
    var refusal: launch_frame.Refusal = undefined;
    try launch_frame.parse(std.testing.allocator, bytes, &frame, &refusal);
    const json = try std.json.parseFromSliceLeaky(Value, allocator, bytes, .{});
    try std.testing.expectEqual(@typeInfo(launch_frame.Wire).@"struct".field_names.len, json.object.count());
    const schema = document.schemas.get("LaunchFrame").?;
    try std.testing.expect(conforms(document.schemas, schema, json));
    try std.testing.expectEqualStrings("/tmp/ca.pem", frame.ca_file.slice());
    try std.testing.expectEqual(@as(usize, 1), frame.presets.len);
    try std.testing.expectEqual(@as(usize, 1), frame.mcp_server_count);
    // Defaults are omittable; nullable capacity is distinct from omission.
    const minimal = try std.json.parseFromSliceLeaky(Value, allocator,
        \\{"v":1,"store":"/tmp/store","provider":{"kind":"openai_key","baseUrl":"https://api.openai.com/v1","key":"test-key"},"runtimeDir":"/tmp/rui","activeCapacity":null}
    , .{});
    try std.testing.expect(conforms(document.schemas, schema, minimal));
    const minimal_bytes = try std.json.Stringify.valueAlloc(allocator, minimal, .{});
    var minimal_frame: launch_frame.Frame = .{};
    defer minimal_frame.deinit();
    try launch_frame.parse(std.testing.allocator, minimal_bytes, &minimal_frame, &refusal);
    // Closed wire objects must reject renamed or missing fields, including
    // fields inside MCP entries and the reused agent-spec schema.
    const invalid = [_][]const u8{
        \\{"v":1,"store":"/tmp/store","provider":{"kind":"openai_key","baseUrl":"https://api.openai.com/v1","key":"test-key","caFile":false},"runtimeDir":"/tmp/rui"}
        ,
        \\{"v":1,"store":"/tmp/store","provider":{"kind":"openai_key","baseUrl":"https://api.openai.com/v1","key":"test-key"},"runtimeDirectory":"/tmp/rui"}
        ,
        \\{"v":1,"store":"/tmp/store","provider":{"kind":"openai_key","baseUrl":"https://api.openai.com/v1","key":"test-key"},"runtimeDir":"/tmp/rui","mcpServers":[{"name":"tools","url":"http://127.0.0.1:1234/mcp","bearerToken":"test-token","timeoutMs":1000}]}
        ,
        \\{"v":1,"store":"/tmp/store","provider":{"kind":"openai_key","baseUrl":"https://api.openai.com/v1","key":"test-key"},"runtimeDir":"/tmp/rui","presets":{"review":{"model":"custom","tools":[],"effort":"low","permissionMode":"ask"}}}
        ,
    };
    for (invalid) |text| {
        const invalid_json = try std.json.parseFromSliceLeaky(Value, allocator, text, .{});
        try std.testing.expect(!conforms(document.schemas, schema, invalid_json));
        try std.testing.expectError(error.LaunchFrameInvalid, launch_frame.parse(std.testing.allocator, text, &minimal_frame, &refusal));
    }
    inline for (std.meta.tags(launch_frame.StartError)) |code| {
        const line = try std.json.Stringify.valueAlloc(allocator, .{ .rui_start_error = .{ .code = code, .message = "refused" } }, .{});
        const error_json = try std.json.parseFromSliceLeaky(Value, allocator, line, .{});
        try std.testing.expect(conforms(document.schemas, document.schemas.get("StartError").?, error_json));
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
    if (rules.get("anyOf")) |alternatives| {
        for (alternatives.array.items) |alternative| if (conforms(schemas, alternative, json)) return true;
        return false;
    }
    if (rules.get("const")) |expected| return equal(expected, json);
    if (rules.get("enum")) |names| {
        for (names.array.items) |name| if (equal(name, json)) return true;
        return false;
    }
    const type_rule = rules.get("type") orelse return true;
    if (type_rule == .array) {
        for (type_rule.array.items) |kind| if (conformsKind(schemas, rules, kind.string, json)) return true;
        return false;
    }
    return conformsKind(schemas, rules, type_rule.string, json);
}

fn conformsKind(schemas: ObjectMap, rules: ObjectMap, kind: []const u8, json: Value) bool {
    if (std.mem.eql(u8, kind, "integer")) return json == .integer;
    if (std.mem.eql(u8, kind, "null")) return json == .null;
    if (std.mem.eql(u8, kind, "boolean")) return json == .bool;
    if (std.mem.eql(u8, kind, "string")) {
        if (json != .string) return false;
        if (rules.get("maxLength")) |limit| if (json.string.len > limit.integer) return false;
        if (rules.get("pattern")) |pattern| return matches(pattern.string, json.string);
        return true;
    }
    if (std.mem.eql(u8, kind, "array")) {
        if (json != .array) return false;
        if (rules.get("maxItems")) |limit| if (json.array.items.len > limit.integer) return false;
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
        if (rules.get("maxProperties")) |limit| if (json.object.count() > limit.integer) return false;
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
    if (std.mem.startsWith(u8, pattern, "^[A-Za-z0-9_-]{1,")) {
        const maximum = std.fmt.parseInt(usize, pattern["^[A-Za-z0-9_-]{1,".len .. pattern.len - "}$".len], 10) catch unreachable;
        if (text.len == 0 or text.len > maximum) return false;
        for (text) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
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

    // The model list is written in code, not as a shape.
    const ids = "gpt-6.1-sol\nmy\"model\n";
    try out.writer.writeAll(protocol.model_list_reply.head);
    try model_list.writeProviders(&out.writer, &.{
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
    try facts.writeJson(&out.writer);
    try Case.check(schemas, "ActivityPageReply", out.written(), a);

    out.clearRetainingCapacity();
    const row: protocol.SessionRow = .{ .tools = try .of(&.{"bash"}), .label = .{} };
    try protocol.writeShape(&out.writer, protocol.session_list_reply.head, .{});
    try row.writeJson(&out.writer);
    try protocol.writeShape(&out.writer, protocol.session_list_reply.last_tail, .{ protocol.ListDelta.full, "x" });
    try Case.check(schemas, "ListSessionsReply", out.written(), a);

    // These are the Store's real streaming reports, not schema examples:
    // an added hand-written field must fail additionalProperties here.
    try store.checkSessionReportsForTesting(Case{ .schemas = schemas, .allocator = a });
}

test "Message observation schema requires Host state and bounds recovery" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var document: Document = .init(allocator);
    const built = try document.build();
    const schemas = built.object.get("components").?.object.get("schemas").?.object;
    const schema = schemas.get("ObserveCommandReply").?;
    const prefix = "{\"version\":\"" ++ protocol.wire_version ++ "\",\"type\":\"command_observation\",\"key\":\"k\",\"observation\":{";
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
    const mutations = [_]protocol.CommandKind{ .configure, .message, .session_stop, .model_interruption, .permission_decision };
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
    pub const openapi_shape = protocol.ActivitySearchFacts.Item.head ++ .{ ListOf(protocol.ActivitySearchFacts.Hit), "]}" };
};
