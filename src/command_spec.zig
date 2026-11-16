const std = @import("std");

pub const CommandKind = enum {
    configure,
    message,
    session_stop,
    session_archive,
    model_interruption,
    permission_decision,
    session_pin,
    action_background,

    pub fn route(self: CommandKind) []const u8 {
        return switch (self) {
            inline else => |kind| spec(kind).route,
        };
    }
};

/// Fields owned by a command kind, apart from the common observation envelope.
pub const ObservationField = enum {
    revision,
    created,
    input,
    state,
    queue,
    binding,
    result,
    work,
    recovery,
    selection,
    archived,
    pinned,
    completion,
    interruption_target,
    permission_target,
    action_target,
    action_selection,
};

pub const ObservationFields = struct {
    always: []const ObservationField = &.{},
    accepted: []const ObservationField = &.{},
    /// Message fields whose presence also depends on its processing state.
    conditional: []const ObservationField = &.{},

    pub fn contains(fields: []const ObservationField, field: ObservationField) bool {
        return std.mem.indexOfScalar(ObservationField, fields, field) != null;
    }
};

pub const Spec = struct {
    route: []const u8,
    reply_type: []const u8,
    summary: []const u8,
    Request: type,
    Observation: type,
    subject_name: ?[]const u8 = null,
    observation_fields: ObservationFields = .{},
    fence_message: []const u8,
    is_control: bool = true,

    pub fn Reply(comptime self: Spec, comptime Wire: type) type {
        const name = self.reply_type;
        return @field(Wire, name);
    }

    pub fn Subject(comptime self: Spec, comptime Subjects: type) type {
        return if (self.subject_name) |name| @field(Subjects, name) else []const u8;
    }

    pub fn replyShapes(comptime self: Spec, comptime Wire: type) type {
        const r = self.Reply(Wire);
        return Shapes(if (@hasDecl(r, "accepted_skills"))
            .{ r.accepted, r.accepted_skills, r.rejected }
        else
            .{ r.accepted, r.rejected });
    }
};

fn Shape(comptime value: anytype) type {
    return struct {
        pub const shape = value;
    };
}

fn Shapes(comptime values_: anytype) type {
    return struct {
        pub const values = values_;
    };
}

fn Request(comptime name: []const u8, comptime member: ?[]const u8) type {
    return struct {
        fn shape(comptime Wire: type) type {
            const value = @field(Wire, name);
            return Shape(if (member) |field| @field(value, field) else value);
        }
        pub fn maxBytes(comptime Wire: type) ?usize {
            return Wire.shapeBytes(shape(Wire).shape);
        }
        pub const examples = .{};
        pub fn schema(comptime Schema: type) type {
            return shape(Schema.Wire);
        }
    };
}

fn Observation(comptime name: []const u8) type {
    return struct {
        pub fn shapes(comptime Wire: type) type {
            return Shapes(.{ .{}, @field(Wire.command_observation_reply, name) });
        }
    };
}

const MessageObservation = struct {
    pub fn shapes(comptime Wire: type) type {
        return Shapes(Wire.command_observation_reply.message_variants);
    }
};

const ActionObservation = struct {
    pub fn shapes(comptime Wire: type) type {
        const o = Wire.command_observation_reply;
        return Shapes(.{ o.action_target, o.action_target ++ o.action_selection });
    }
};

const ConfigureRequest = struct {
    // Content is streamed and does not have a fixed request bound.
    pub fn maxBytes(comptime Wire: type) ?usize {
        _ = Wire;
        return null;
    }
    pub const examples = .{};
    pub fn schema(comptime S: type) type {
        const r = S.Wire.configure_request;
        return Shape(r.head ++ .{S.Configuration} ++ .{
            S.Optional(r.reload_skills),
            S.Optional(r.require_model),
            S.Optional(r.preset),
        } ++ r.tail);
    }
};

const MessageRequest = struct {
    pub fn maxBytes(comptime Wire: type) ?usize {
        _ = Wire;
        return null;
    }
    pub const examples = .{
        .{ 2, "\"\"", "\"aaaaaa\"" },
        .{ 3, "{\"store\":\"/s\",\"session\":\"aaaaaa\"}", "null" },
    };
    pub fn schema(comptime S: type) type {
        const r = S.Wire.message_request;
        return Shape(r.head ++ .{S.Sender} ++ r.sender_handle ++ .{
            S.Optional(r.configuration ++ .{S.Configuration}),
        } ++ r.text ++ .{S.Content} ++ r.text_tail ++ .{
            S.Optional(r.require_model),
        } ++ r.tail);
    }
};

const ArchiveRequest = struct {
    pub fn maxBytes(comptime Wire: type) ?usize {
        return Wire.shapeBytes(Wire.session_archive_request.all);
    }
    pub const examples = .{};
    pub fn schema(comptime S: type) type {
        const r = S.Wire.session_archive_request;
        return Shape(r.head ++ .{S.Optional(r.archived)} ++ r.tail);
    }
};

/// Exhaustive and compile-time only: Store admission and request parsers remain typed per kind.
pub fn spec(comptime kind: CommandKind) Spec {
    return switch (kind) {
        .configure => .{
            .route = "/v1/configure",
            .reply_type = "configuration_reply",
            .summary = "Creates or reconfigures a Session. Retried by its key.",
            .Request = ConfigureRequest,
            .Observation = Observation("revision"),
            .observation_fields = .{ .accepted = &.{ .revision, .created } },
            .fence_message = "configuration save",
            .is_control = false,
        },
        .message => .{
            .route = "/v1/message",
            .reply_type = "message_reply",
            .summary = "Sends a Message to a Session, or creates the Session when `session` is empty. Retried by its key. Each `/name` word in the text that names a skill in the recipient's catalog appends that skill to what the model reads; the text is saved as written. Only an empty `session` carries (and requires) `configuration`; `require_model` is allowed only with it. The body starts with the client environment, `X-Rui-Environment-Bytes` long, before the JSON.",
            .Request = MessageRequest,
            .Observation = MessageObservation,
            .observation_fields = .{
                .always = &.{.state},
                .conditional = &.{ .input, .queue, .binding, .result, .work, .recovery },
            },
            .fence_message = "message save",
            .is_control = false,
        },
        .session_stop => .{
            .route = "/v1/control/session-stop",
            .reply_type = "session_stop_reply",
            .summary = "Stops a Session's current and queued work. Retried by its key.",
            .Request = Request("session_stop_request", null),
            .Observation = Observation("session_stop"),
            .observation_fields = .{ .accepted = &.{ .selection, .completion } },
            .fence_message = "Session stop save",
        },
        .session_archive => .{
            .route = "/v1/control/session-archive",
            .reply_type = "session_archive_reply",
            .summary = "Archives or restores a Session. Archiving stops current and queued work. Retried by its key.",
            .Request = ArchiveRequest,
            .Observation = Observation("session_archive"),
            .observation_fields = .{ .accepted = &.{ .archived, .completion } },
            .fence_message = "Session archive save",
        },
        .session_pin => .{
            .route = "/v1/control/session-pin",
            .reply_type = "session_pin_reply",
            .summary = "Pins or unpins a Session without changing its work. Retried by its key.",
            .Request = Request("session_pin_request", "all"),
            .Observation = Observation("session_pin"),
            .observation_fields = .{ .accepted = &.{.pinned} },
            .fence_message = "Session pin save",
        },
        .model_interruption => .{
            .route = "/v1/control/model-interruption",
            .reply_type = "model_interruption_reply",
            .summary = "Interrupts one model Operation. Retried by its key.",
            .Request = Request("model_interruption_request", null),
            .Observation = Observation("model_interruption"),
            .subject_name = "ModelInterruptionTarget",
            .observation_fields = .{ .always = &.{.interruption_target} },
            .fence_message = "model interruption save",
        },
        .permission_decision => .{
            .route = "/v1/control/permission-decision",
            .reply_type = "permission_decision_reply",
            .summary = "Allows or denies one Action that waits for permission. Retried by its key.",
            .Request = Request("permission_decision_request", null),
            .Observation = Observation("permission_decision"),
            .subject_name = "PermissionTarget",
            .observation_fields = .{ .always = &.{.permission_target} },
            .fence_message = "permission decision save",
        },
        .action_background => .{
            .route = "/v1/control/action-background",
            .reply_type = "action_background_reply",
            .summary = "Promotes the same Action to Session-owned background work and returns its immutable call receipt selection. Completion is read explicitly with read-action; no final input or model wake is delivered. Retried by its key.",
            .Request = Request("action_background_request", null),
            .Observation = ActionObservation,
            .subject_name = "ActionBackgroundTarget",
            .observation_fields = .{ .always = &.{.action_target}, .accepted = &.{.action_selection} },
            .fence_message = "Action background save",
        },
    };
}

test "command_spec covers every kind and preserves routes and request limits" {
    const protocol = @import("protocol.zig");
    const host_reply = @import("host_reply.zig");
    const Subjects = struct {
        pub const ModelInterruptionTarget = @import("command_reply.zig").ModelInterruptionTarget;
        pub const PermissionTarget = host_reply.PermissionTarget;
        pub const ActionBackgroundTarget = host_reply.ActionBackgroundTarget;
    };
    const expected_subjects = .{
        []const u8,                       []const u8,                []const u8, []const u8,
        Subjects.ModelInterruptionTarget, Subjects.PermissionTarget, []const u8, Subjects.ActionBackgroundTarget,
    };
    const expected = .{
        .{ "/v1/configure", "configuration_reply", @as(?usize, null) },
        .{ "/v1/message", "message_reply", @as(?usize, null) },
        .{ "/v1/control/session-stop", "session_stop_reply", protocol.shapeBytes(protocol.session_stop_request) },
        .{ "/v1/control/session-archive", "session_archive_reply", protocol.shapeBytes(protocol.session_archive_request.all) },
        .{ "/v1/control/model-interruption", "model_interruption_reply", protocol.shapeBytes(protocol.model_interruption_request) },
        .{ "/v1/control/permission-decision", "permission_decision_reply", protocol.shapeBytes(protocol.permission_decision_request) },
        .{ "/v1/control/session-pin", "session_pin_reply", protocol.shapeBytes(protocol.session_pin_request.all) },
        .{ "/v1/control/action-background", "action_background_reply", protocol.shapeBytes(protocol.action_background_request) },
    };
    inline for (comptime std.meta.tags(CommandKind), expected, 0..) |kind, original, index| {
        const facts = comptime spec(kind);
        try std.testing.expectEqualStrings(original[0], facts.route);
        try std.testing.expectEqualStrings(original[1], facts.reply_type);
        try std.testing.expectEqual(@as(?usize, original[2]), facts.Request.maxBytes(protocol));
        try std.testing.expectEqual(index >= 2, facts.is_control);
        try std.testing.expect(facts.Subject(Subjects) == expected_subjects[index]);
        _ = facts.Reply(protocol).max_bytes;
        _ = facts.Observation.shapes(protocol).values;
        try std.testing.expect(facts.summary.len != 0 and facts.fence_message.len != 0);
    }
}
