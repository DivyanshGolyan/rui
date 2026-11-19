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
    action_stop,

    pub fn route(self: CommandKind) []const u8 {
        return switch (self) {
            inline else => |kind| spec(kind).route,
        };
    }
};

pub const Spec = struct {
    route: []const u8,
    reply_type: []const u8,
    summary: []const u8,
    subject_type: ?[]const u8 = null,
    fence_message: []const u8,
    Request: type,
    Observation: type,
    is_control: bool = true,

    pub fn Subject(comptime self: Spec, comptime Subjects: type) type {
        return if (self.subject_type) |name| @field(Subjects, name) else []const u8;
    }

    pub fn Reply(comptime self: Spec, comptime Wire: type) type {
        const name = self.reply_type;
        return @field(Wire, name);
    }

    pub fn replyShapes(comptime self: Spec, comptime Wire: type) type {
        const r = self.Reply(Wire);
        return Shapes(if (@hasDecl(r, "accepted_skills"))
            .{ r.accepted, r.accepted_skills, r.rejected }
        else if (@hasDecl(r, "rejected_parts"))
            .{ r.accepted, r.rejected, r.rejected_parts }
        else
            .{ r.accepted, r.rejected });
    }

    pub fn observationDecoderShapes(comptime self: Spec, comptime Wire: type) type {
        @setEvalBranchQuota(2_000_000);
        const o = Wire.command_observation_reply;
        const head = o.head(kindFor(self));
        const accepted_head = .{ head[0], head[1], head[2], head[3], head[4] ++ "accepted" ++ head[6], head[7] };
        const rejected_head = .{ head[0], head[1], head[2], head[3], head[4] ++ "rejected" ++ head[6], head[7] };
        return Shapes(
            observationPayloadShapes(self.Observation.accepted(Wire).values, 0, accepted_head, o.tail, Wire).values ++
                observationPayloadShapes(self.Observation.rejected(Wire).values, 0, rejected_head, o.code ++ o.tail, Wire).values,
        );
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

fn Observation(comptime name: []const u8, comptime retained_on_rejection: bool) type {
    return struct {
        pub fn shapes(comptime Wire: type) type {
            return Shapes(.{ .{}, @field(Wire.command_observation_reply, name) });
        }

        pub fn accepted(comptime Wire: type) type {
            return Shapes(.{@field(Wire.command_observation_reply, name)});
        }

        pub fn rejected(comptime Wire: type) type {
            return Shapes(.{if (retained_on_rejection) @field(Wire.command_observation_reply, name) else .{}});
        }
    };
}

const MessageObservation = struct {
    pub fn shapes(comptime Wire: type) type {
        return Shapes(accepted(Wire).values ++ rejected(Wire).values);
    }

    pub fn accepted(comptime Wire: type) type {
        return Shapes(Wire.command_observation_reply.message_accepted);
    }

    pub fn rejected(comptime Wire: type) type {
        return Shapes(.{Wire.command_observation_reply.message_rejected});
    }
};

const ActionObservation = struct {
    pub fn shapes(comptime Wire: type) type {
        const o = Wire.command_observation_reply;
        return Shapes(.{ o.action_target, o.action_target ++ o.action_selection });
    }

    pub fn accepted(comptime Wire: type) type {
        return Shapes(.{shapes(Wire).values[1]});
    }

    pub fn rejected(comptime Wire: type) type {
        return Shapes(.{shapes(Wire).values[0]});
    }
};

const StopObservation = struct {
    pub fn shapes(comptime Wire: type) type {
        const o = Wire.command_observation_reply;
        return Shapes(.{ o.action_target, o.action_target ++ o.action_stop });
    }
    pub fn accepted(comptime Wire: type) type {
        return Shapes(.{shapes(Wire).values[1]});
    }
    pub fn rejected(comptime Wire: type) type {
        return Shapes(.{shapes(Wire).values[0]});
    }
};

fn kindFor(comptime facts: Spec) CommandKind {
    inline for (std.meta.tags(CommandKind)) |kind| {
        if (std.mem.eql(u8, facts.route, spec(kind).route)) return kind;
    }
    unreachable;
}

// Permission observations use the same consequential WorkState validation as
// every other message state, while the wire writer keeps its compact literal.
fn decoderObservationPayload(comptime payload: anytype, comptime index: usize, comptime Wire: type) type {
    if (index == payload.len) return Shape(.{});
    if (@TypeOf(payload[index]) != Wire.Hole and @TypeOf(payload[index]) != std.meta.Tag(Wire.Hole) and
        std.mem.eql(u8, payload[index], Wire.command_observation_reply.permission_work[0]))
    {
        return Shape(Wire.command_observation_reply.work ++ decoderObservationPayload(payload, index + Wire.command_observation_reply.permission_work.len, Wire).shape);
    }
    return Shape(.{payload[index]} ++ decoderObservationPayload(payload, index + 1, Wire).shape);
}

fn observationPayloadShapes(comptime payloads: anytype, comptime index: usize, comptime prefix: anytype, comptime suffix: anytype, comptime Wire: type) type {
    if (index == payloads.len) return Shapes(.{});
    return Shapes(.{prefix ++ decoderObservationPayload(payloads[index], 0, Wire).shape ++ suffix} ++
        observationPayloadShapes(payloads, index + 1, prefix, suffix, Wire).values);
}

fn observationDecoderKinds(comptime Wire: type, comptime index: usize) type {
    const kinds = std.meta.tags(CommandKind);
    if (index == kinds.len) return Shapes(.{});
    return Shapes(spec(kinds[index]).observationDecoderShapes(Wire).values ++ observationDecoderKinds(Wire, index + 1).values);
}

pub fn observationDecoderShapes(comptime Wire: type) type {
    @setEvalBranchQuota(2_000_000);
    return Shapes(.{ Wire.command_observation_reply.absent, Wire.command_observation_reply.not_modified } ++ observationDecoderKinds(Wire, 0).values);
}

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
    pub fn partsSchema(comptime S: type) type {
        const r = S.Wire.message_request;
        return Shape(r.head ++ .{S.Sender} ++ r.sender_handle ++ .{
            S.Optional(r.configuration ++ .{S.Configuration}),
        } ++ r.parts ++ .{S.Parts} ++ .{
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
            .fence_message = "configuration save",
            .route = "/v1/configure",
            .reply_type = "configuration_reply",
            .summary = "Creates or reconfigures a Session. Retried by its key.",
            .Request = ConfigureRequest,
            .Observation = Observation("revision", false),
            .is_control = false,
        },
        .message => .{
            .fence_message = "message save",
            .route = "/v1/message",
            .reply_type = "message_reply",
            .summary = "Sends a Message to a Session, or creates the Session when `session` is empty. Retried by its key. Each `/name` word in the text that names a skill in the recipient's catalog appends that skill to what the model reads; the text is saved as written. Only an empty `session` carries (and requires) `configuration`; `require_model` is allowed only with it. The body starts with the client environment, `X-Rui-Environment-Bytes` long, before the JSON.",
            .Request = MessageRequest,
            .Observation = MessageObservation,
            .is_control = false,
        },
        .session_stop => .{
            .fence_message = "Session stop save",
            .route = "/v1/control/session-stop",
            .reply_type = "session_stop_reply",
            .summary = "Stops a Session's current and queued work. Retried by its key.",
            .Request = Request("session_stop_request", null),
            .Observation = Observation("session_stop", false),
        },
        .session_archive => .{
            .fence_message = "Session archive save",
            .route = "/v1/control/session-archive",
            .reply_type = "session_archive_reply",
            .summary = "Archives or restores a Session. Archiving stops current and queued work. Retried by its key.",
            .Request = ArchiveRequest,
            .Observation = Observation("session_archive", false),
        },
        .session_pin => .{
            .fence_message = "Session pin save",
            .route = "/v1/control/session-pin",
            .reply_type = "session_pin_reply",
            .summary = "Pins or unpins a Session without changing its work. Retried by its key.",
            .Request = Request("session_pin_request", "all"),
            .Observation = Observation("session_pin", false),
        },
        .model_interruption => .{
            .subject_type = "model_interruption",
            .fence_message = "model interruption save",
            .route = "/v1/control/model-interruption",
            .reply_type = "model_interruption_reply",
            .summary = "Interrupts one model Operation. Retried by its key.",
            .Request = Request("model_interruption_request", null),
            .Observation = Observation("model_interruption", true),
        },
        .permission_decision => .{
            .subject_type = "permission_decision",
            .fence_message = "permission decision save",
            .route = "/v1/control/permission-decision",
            .reply_type = "permission_decision_reply",
            .summary = "Allows or denies one Action that waits for permission. Retried by its key.",
            .Request = Request("permission_decision_request", null),
            .Observation = Observation("permission_decision", true),
        },
        .action_background => .{
            .subject_type = "action_background",
            .fence_message = "Action background save",
            .route = "/v1/control/action-background",
            .reply_type = "action_background_reply",
            .summary = "Promotes the same Action to Session-owned background work and returns its immutable call receipt selection. Completion is read explicitly with read-action; no final input or model wake is delivered. Retried by its key.",
            .Request = Request("action_background_request", null),
            .Observation = ActionObservation,
        },
        .action_stop => .{
            .subject_type = "action_stop",
            .fence_message = "Action stop save",
            .route = "/v1/control/action-stop",
            .reply_type = "action_stop_reply",
            .summary = "Selects one owned Action for stop, preserving an existing Resolution. Read completion with read-action. Retried by its key.",
            .Request = Request("action_stop_request", null),
            .Observation = StopObservation,
        },
    };
}

test "command_spec covers every kind and preserves routes and request limits" {
    const protocol = @import("protocol.zig");
    const expected = .{
        .{ "/v1/configure", "configuration_reply", @as(?usize, null), "configuration save" },
        .{ "/v1/message", "message_reply", @as(?usize, null), "message save" },
        .{ "/v1/control/session-stop", "session_stop_reply", protocol.shapeBytes(protocol.session_stop_request), "Session stop save" },
        .{ "/v1/control/session-archive", "session_archive_reply", protocol.shapeBytes(protocol.session_archive_request.all), "Session archive save" },
        .{ "/v1/control/model-interruption", "model_interruption_reply", protocol.shapeBytes(protocol.model_interruption_request), "model interruption save" },
        .{ "/v1/control/permission-decision", "permission_decision_reply", protocol.shapeBytes(protocol.permission_decision_request), "permission decision save" },
        .{ "/v1/control/session-pin", "session_pin_reply", protocol.shapeBytes(protocol.session_pin_request.all), "Session pin save" },
        .{ "/v1/control/action-background", "action_background_reply", protocol.shapeBytes(protocol.action_background_request), "Action background save" },
        .{ "/v1/control/action-stop", "action_stop_reply", protocol.shapeBytes(protocol.action_stop_request), "Action stop save" },
    };
    inline for (comptime std.meta.tags(CommandKind), expected, 0..) |kind, original, index| {
        const facts = comptime spec(kind);
        try std.testing.expectEqualStrings(original[0], facts.route);
        try std.testing.expectEqualStrings(original[1], facts.reply_type);
        try std.testing.expectEqual(@as(?usize, original[2]), facts.Request.maxBytes(protocol));
        try std.testing.expectEqualStrings(original[3], facts.fence_message);
        try std.testing.expectEqual(index >= 2, facts.is_control);
        _ = facts.Reply(protocol).max_bytes;
        _ = facts.Observation.shapes(protocol).values;
        try std.testing.expect(facts.summary.len != 0);
    }
}

test "command_spec resolves every subject from injected types" {
    const Subjects = struct {
        pub const model_interruption = struct { turn: u64 };
        pub const permission_decision = struct { decision: bool };
        pub const action_background = struct { action: u64 };
        pub const action_stop = struct { action: u64 };
    };
    const expected = .{
        []const u8,
        []const u8,
        []const u8,
        []const u8,
        Subjects.model_interruption,
        Subjects.permission_decision,
        []const u8,
        Subjects.action_background,
        Subjects.action_stop,
    };
    inline for (comptime std.meta.tags(CommandKind), expected) |kind, Expected| {
        try std.testing.expect(spec(kind).Subject(Subjects) == Expected);
    }
}

fn mutationDecoderKinds(comptime Wire: type, comptime index: usize) type {
    const kinds = std.meta.tags(CommandKind);
    if (index == kinds.len) return Shapes(.{});
    const facts = spec(kinds[index]);
    return Shapes(facts.replyShapes(Wire).values ++ .{facts.Reply(Wire).conflict} ++ mutationDecoderKinds(Wire, index + 1).values);
}

pub fn mutationDecoderShapes(comptime Wire: type) type {
    return Shapes(.{Wire.error_reply} ++ mutationDecoderKinds(Wire, 0).values);
}
