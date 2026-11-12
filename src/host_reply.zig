//! The JSON a Host replies with: each reply's renderer, written from the
//! shape protocol.zig declares for it, over the values the Store answered
//! with. The server sends what these write.
const std = @import("std");
const protocol = @import("protocol.zig");
const change_ring = @import("change_ring.zig");
const command_reply = @import("command_reply.zig");
const AttemptBinding = @import("attempt.zig").AttemptBinding;
const skill_suggestions = @import("skill_suggestions.zig");
const activity_reply = @import("activity_reply.zig");

pub fn activityPageBytes(page: *const protocol.ActivityFacts) usize {
    return if (page.not_modified) protocol.shapeBytes(activity_reply.page_reply.unchanged) else activity_reply.max_page_bytes;
}

pub fn renderActivityPage(out: protocol.JsonOut, page: *const protocol.ActivityFacts) error{BufferTooLarge}!void {
    activity_reply.writePage(out.writer, page) catch return error.BufferTooLarge;
}

pub fn renderActivitySearch(out: protocol.JsonOut, page: *const protocol.ActivitySearchFacts) error{BufferTooLarge}!void {
    activity_reply.writeSearch(out.writer, page) catch return error.BufferTooLarge;
}

/// The HTTP status of a mutation reply: the same four outcomes for each.
pub fn httpStatus(result: anytype) u16 {
    return switch (result) {
        .accepted, .rejected => 200,
        .conflict => 409,
        .infrastructure_failure => 500,
    };
}

/// `session` is the Session the request named.
pub fn renderConfigureReply(
    response: protocol.JsonOut,
    session: []const u8,
    result: command_reply.ConfigureReply,
) !void {
    const shapes = protocol.configuration_reply;
    try switch (result) {
        .accepted => |value| if (value.skills) |status| response.appendShape(shapes.accepted_skills, .{ value.replayed, value.session.slice(), value.revision, status }) else response.appendShape(shapes.accepted, .{ value.replayed, value.session.slice(), value.revision, value.created }),
        .rejected => |value| renderToolRejection(response, session, value, shapes.rejected),
        .conflict => response.appendShape(shapes.conflict, .{session}),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

/// `session` is the Session the request named.
pub fn renderMessageReply(
    response: protocol.JsonOut,
    session: []const u8,
    result: command_reply.MessageReply,
) !void {
    const shapes = protocol.message_reply;
    try switch (result) {
        .accepted => |value| response.appendShape(shapes.accepted, .{ value.replayed, value.session.slice(), value.admission_id, value.content.length, value.content.digest, value.admission_id }),
        .rejected => |value| renderToolRejection(response, session, value, shapes.rejected),
        .conflict => response.appendShape(shapes.conflict, .{session}),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

// Rare diagnostic scratch stays off the engine and the ordinary reply frame.
noinline fn renderToolRejection(response: protocol.JsonOut, session: []const u8, value: anytype, comptime shape: anytype) !void {
    var buffer: [@import("tool_record.zig").HostToolSet.max_refusal_message_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const message: ?[]const u8 = if (value.message) |detail| message: {
        try detail.write(&writer);
        break :message writer.buffered();
    } else null;
    if (comptime @hasField(@TypeOf(value), "content")) {
        try response.appendShape(shape, .{ value.replayed, session, value.code, message, value.content.length, value.content.digest });
    } else try response.appendShape(shape, .{ value.replayed, session, value.code, message });
}

pub fn renderConversationPage(response: protocol.JsonOut, page: *const command_reply.PublicConversationPage) !void {
    const shapes = protocol.conversation_page_reply;
    try response.appendShape(shapes.head, .{page.end});
    for (page.items[0..page.count], 0..) |item, index| {
        if (index != 0) try response.append(",");
        switch (item.kind) {
            .hosted_call => try response.appendShape(shapes.hosted_call, .{ item.position, item.ordinal }),
            inline else => |kind| try response.appendShape(shapes.item(kind), .{ item.position, item.ordinal, item.content.length, item.content.digest }),
        }
        switch (item.kind) {
            .user => if (item.admitted_at) |second| try response.appendShape(shapes.admission, .{ second, protocol.NamedPeerJson.optional(item.sender) }),
            .tool_result, .hosted_call => if (item.presentation) |presentation| try response.appendShape(shapes.presentation, .{protocol.ToolPresentationJson{ .value = presentation }}),
            .assistant => {},
        }
        try response.appendShape(shapes.item_end, .{});
    }
    if (page.more) {
        const last = page.items[page.count - 1];
        try response.appendShape(shapes.more, .{ last.position, last.ordinal });
    } else try response.appendShape(shapes.last, .{});
}

pub fn renderSessionStopReply(
    response: protocol.JsonOut,
    session: []const u8,
    result: command_reply.SessionStopReply,
) !void {
    const shapes = protocol.session_stop_reply;
    try switch (result) {
        .accepted => |value| response.appendShape(shapes.accepted, .{ value.replayed, session, value.selection.selected_turn_id, value.selection.admission_cutoff, value.completion }),
        .rejected => |value| response.appendShape(shapes.rejected, .{ value.replayed, session, value.code }),
        .conflict => response.appendShape(shapes.conflict, .{session}),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

pub fn renderSessionArchiveReply(
    response: protocol.JsonOut,
    session: []const u8,
    result: command_reply.SessionArchiveReply,
) !void {
    const shapes = protocol.session_archive_reply;
    try switch (result) {
        .accepted => |value| response.appendShape(shapes.accepted, .{ value.replayed, session, value.archived, value.completion }),
        .rejected => |value| response.appendShape(shapes.rejected, .{ value.replayed, session, value.code }),
        .conflict => response.appendShape(shapes.conflict, .{session}),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

pub fn renderModelInterruptionReply(
    response: protocol.JsonOut,
    target: command_reply.ModelInterruptionTarget,
    result: command_reply.ModelInterruptionReply,
) !void {
    const shapes = protocol.model_interruption_reply;
    const session = target.session.slice();
    try switch (result) {
        .accepted => |value| response.appendShape(shapes.accepted, .{ value.replayed, session, target.turn_id, target.operation_id }),
        .rejected => |value| response.appendShape(shapes.rejected, .{ value.replayed, session, target.turn_id, target.operation_id, value.code }),
        .conflict => response.appendShape(shapes.conflict, .{ session, target.turn_id, target.operation_id }),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

/// The decision a permission reply answers, as the request named it.
pub const PermissionTarget = struct {
    session: protocol.Bounded(protocol.max_session_bytes),
    action_id: u64,
    decision: protocol.PermissionDecision,
};

pub fn renderPermissionDecisionReply(
    response: protocol.JsonOut,
    target: PermissionTarget,
    result: command_reply.PermissionDecisionReply,
) !void {
    const shapes = protocol.permission_decision_reply;
    const session = target.session.slice();
    try switch (result) {
        .accepted => |value| response.appendShape(shapes.accepted, .{ value.replayed, session, target.action_id, target.decision }),
        .rejected => |value| response.appendShape(shapes.rejected, .{ value.replayed, session, target.action_id, target.decision, value.code }),
        .conflict => response.appendShape(shapes.conflict, .{ session, target.action_id, target.decision }),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

pub fn commandObservationBytes(observed: *const command_reply.Observed) usize {
    const shapes = protocol.command_observation_reply;
    return switch (observed.*) {
        .not_modified => protocol.shapeBytes(shapes.not_modified),
        .full => |*full| if (full.observation.status == .absent) protocol.shapeBytes(shapes.absent) else switch (full.observation.kind) {
            inline else => |_, kind| shapes.maxBytes(kind),
        },
    };
}

pub fn renderCommandObservation(response: protocol.JsonOut, key: []const u8, observed: *const command_reply.Observed) !void {
    var token: [change_ring.SessionToken.max_bytes]u8 = undefined;
    switch (observed.*) {
        .not_modified => |since| try response.appendShape(protocol.command_observation_reply.not_modified, .{ key, since.format(&token) }),
        .full => |*full| try renderFullCommandObservation(response, key, &full.observation, if (full.token) |since| since.format(&token) else null),
    }
}

pub fn renderFullCommandObservation(
    response: protocol.JsonOut,
    key: []const u8,
    observation: *const command_reply.CommandObservation,
    since: ?[]const u8,
) !void {
    const shapes = protocol.command_observation_reply;
    if (observation.status == .absent) return response.appendShape(shapes.absent, .{key});
    switch (observation.kind) {
        inline else => |_, kind| try response.appendShape(shapes.head(kind), .{ key, since, observation.status, observation.target.slice() }),
    }
    if (observation.code.len != 0) try response.appendShape(shapes.code, .{observation.code.slice()});
    if (observation.kind == .message) try response.appendShape(shapes.state, .{observation.requestState() orelse return error.InvalidCommandObservation});
    switch (observation.kind) {
        .configure => |configured| if (observation.status == .accepted) try response.appendShape(shapes.revision, .{ configured.revision, configured.created }),
        .message => |*maybe_message| if (maybe_message.*) |*message| {
            try response.appendShape(shapes.input, .{ message.content.length, message.content.digest });
            if (message.queue) |accepted| {
                try response.appendShape(shapes.queue, .{ accepted.admission_id, message.admitted_at });
                const binding: ?AttemptBinding = switch (accepted.state) {
                    .processing => |value| value,
                    .completed => |value| value.binding,
                    .cancelled => |value| value.binding,
                    .failed => |value| value.binding,
                    .queued, .excluded => null,
                };
                if (binding) |bound| try response.appendShape(shapes.binding, .{ bound.turn_id, bound.operation_id, bound.attempt_ordinal });
                switch (accepted.state) {
                    .completed => |value| try response.appendShape(shapes.completed, .{ value.answer.length, value.answer.digest }),
                    .cancelled => |value| try response.appendShape(shapes.cancelled, .{value.code.slice()}),
                    .excluded => |value| try response.appendShape(shapes.cancelled, .{value.code.slice()}),
                    .failed => |value| try response.appendShape(shapes.failed, .{value.code.slice()}),
                    .queued, .processing => {
                        const work = message.work orelse return error.InvalidCommandObservation;
                        try response.appendShape(shapes.work, .{ protocol.WorkStateJson{ .state = work.state }, work.first_action });
                    },
                }
                if (message.recovery.count != 0) try response.appendShape(shapes.recovery, .{protocol.MessageRecoveryJson{
                    .calls = message.recovery.calls[0..message.recovery.count],
                    .more = message.recovery.more,
                }});
            }
        },
        .session_stop => |maybe_stop| if (maybe_stop) |stop| try response.appendShape(shapes.session_stop, .{ stop.selection.selected_turn_id, stop.selection.admission_cutoff, stop.completion }),
        .session_archive => |archive| if (archive) |value| try response.appendShape(shapes.session_archive, .{ value.archived, value.completion }),
        .model_interruption => |target| try response.appendShape(shapes.model_interruption, .{ target.session.slice(), target.turn_id, target.operation_id }),
        .permission_decision => |permission| try response.appendShape(shapes.permission_decision, .{ permission.action_id, permission.decision }),
    }
    try response.appendShape(shapes.tail, .{});
}

/// What `host info` reports, named so no two counts can trade places.
pub const HostInfo = struct {
    store: []const u8,
    instance: protocol.InstanceId,
    active_capacity: u64,
    intake_capacity: u64,
    descriptor_soft_limit: ?u64,
    started_at: u64,
    custody_occupied: u64,
    paused: bool,
    routes: protocol.Routes,
    doublewrite: ?[]const u8,
};

pub fn renderHostInfo(response: protocol.JsonOut, info: HostInfo) !void {
    var digits: [protocol.Hole.maxBytes(.decimal)]u8 = undefined;
    const limit_text = if (info.descriptor_soft_limit) |limit| std.fmt.bufPrint(&digits, "{d}", .{limit}) catch unreachable else "unlimited";
    const routes = info.routes;
    const shape = protocol.host_info_reply;
    try response.appendShape(shape.head, .{ info.store, info.instance, info.active_capacity, info.intake_capacity, limit_text, info.started_at, info.custody_occupied, info.paused });
    if (info.doublewrite) |value| try response.appendShape(shape.doublewrite, .{value});
    try response.appendShape(shape.tail, .{ routes.codex, routes.openai, routes.chatgpt });
}

pub fn renderHostPause(response: protocol.JsonOut, paused: bool) !void {
    try response.appendShape(protocol.host_pause_reply, .{paused});
}

/// Nothing changed since the token: it comes back, with no rows.
pub fn renderSessionsNotModified(response: protocol.JsonOut, since: protocol.SinceToken) !void {
    var token: [protocol.SinceToken.max_bytes]u8 = undefined;
    try response.appendShape(protocol.session_list_reply.head ++ protocol.session_list_reply.last_tail, .{ protocol.ListDelta.not_modified, since.format(&token) });
}

pub fn renderSkillSuggestions(out: protocol.JsonOut, page: *const skill_suggestions.Page) error{BufferTooLarge}!void {
    try out.appendShape(protocol.skill_suggestions_reply.head, .{ page.revision, page.total });
    for (page.entries, 0..) |entry, index| {
        if (index != 0) try out.append(",");
        try out.appendShape(protocol.skill_suggestions_reply.entry, .{ entry.name, entry.description });
    }
    try out.append(protocol.skill_suggestions_reply.tail);
}

pub fn renderStatic(response: protocol.JsonOut, kind: protocol.ErrorType, code: []const u8) !void {
    try response.appendShape(protocol.error_reply, .{ kind, code });
}

test "a mutation's outcome decides its HTTP status" {
    try std.testing.expectEqual(@as(u16, 200), httpStatus(command_reply.MessageReply{ .rejected = .{ .replayed = false, .code = .unknown_session, .content = .{ .length = 0, .digest = @splat(0) } } }));
    try std.testing.expectEqual(@as(u16, 200), httpStatus(command_reply.PermissionDecisionReply{ .accepted = .{ .replayed = true } }));
    try std.testing.expectEqual(@as(u16, 409), httpStatus(command_reply.SessionStopReply.conflict));
    try std.testing.expectEqual(@as(u16, 500), httpStatus(command_reply.ConfigureReply.infrastructure_failure));
}

test "every reply renders its exact worst-case bound from the shape it writes" {
    // Each bound comes from the shape its renderer writes, so the longest
    // value of every variant must reach it exactly. Text a renderer wrote
    // outside its shape, or a hole the bound missed, would fail here.
    const max = std.math.maxInt(u64);
    const escaped_session = @as([protocol.max_session_bytes]u8, @splat(1));
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
    const escaped_code = @as([protocol.max_code_bytes]u8, @splat(1));
    const escaped_store = @as([protocol.max_store_bytes]u8, @splat(1));
    const content: command_reply.ContentReference = .{ .length = max, .digest = @splat(0xff) };
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try session.set(&escaped_session);
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try code.set(&escaped_code);
    const Worst = struct {
        /// The tag a bound must allow for: the longest name.
        fn tag(comptime E: type) E {
            var longest = std.meta.tags(E)[0];
            for (std.meta.tags(E)) |value| {
                if (@tagName(value).len > @tagName(longest).len) longest = value;
            }
            return longest;
        }

        fn reply(render: anytype, subject: anytype, results: anytype) !usize {
            var bytes: usize = 0;
            inline for (results) |result| {
                var response: protocol.ResponseBuffer = .{};
                try response.render(render, .{ subject, result });
                bytes = @max(bytes, response.len);
            }
            return bytes;
        }

        fn observation(key: []const u8, value: command_reply.CommandObservation) !usize {
            var response: protocol.CommandObservationBuffer = .{};
            try response.render(renderFullCommandObservation, .{ key, &value, &@as([change_ring.SessionToken.max_bytes]u8, @splat(1)) });
            return response.len;
        }
    };

    // The semantic diagnostic only contains valid names. Exercise the
    // string hole's arbitrary-escaping bound separately from the other arms.
    const message_expansion = protocol.Hole.maxBytes(.{ .optional_string = @import("tool_record.zig").HostToolSet.max_refusal_message_bytes }) - "null".len;
    try std.testing.expectEqual(protocol.configuration_reply.max_bytes, @max(
        try Worst.reply(renderConfigureReply, @as([]const u8, &escaped_session), .{
            command_reply.ConfigureReply{ .accepted = .{ .replayed = false, .revision = max, .created = false, .session = session, .skills = .unchanged } },
            command_reply.ConfigureReply.conflict,
        }),
        try Worst.reply(renderConfigureReply, @as([]const u8, &escaped_session), .{
            command_reply.ConfigureReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.ConfigurationRejection) } },
        }) + message_expansion,
    ));

    try std.testing.expectEqual(protocol.message_reply.max_bytes, @max(
        try Worst.reply(renderMessageReply, @as([]const u8, &escaped_session), .{
            command_reply.MessageReply{ .accepted = .{ .replayed = false, .admission_id = max, .content = content, .session = session } },
            command_reply.MessageReply.conflict,
        }),
        try Worst.reply(renderMessageReply, @as([]const u8, &escaped_session), .{
            command_reply.MessageReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.MessageRejection), .content = content } },
        }) + message_expansion,
    ));

    try std.testing.expectEqual(protocol.session_stop_reply.max_bytes, try Worst.reply(renderSessionStopReply, @as([]const u8, &escaped_session), .{
        command_reply.SessionStopReply{ .accepted = .{ .replayed = false, .selection = .{ .selected_turn_id = max, .admission_cutoff = max }, .completion = Worst.tag(protocol.SessionStopCompletion) } },
        command_reply.SessionStopReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.SessionStopRejection) } },
        command_reply.SessionStopReply.conflict,
    }));

    try std.testing.expectEqual(protocol.session_archive_reply.max_bytes, try Worst.reply(renderSessionArchiveReply, @as([]const u8, &escaped_session), .{
        command_reply.SessionArchiveReply{ .accepted = .{ .replayed = false, .archived = false, .completion = Worst.tag(protocol.SessionStopCompletion) } },
        command_reply.SessionArchiveReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.SessionArchiveRejection) } },
        command_reply.SessionArchiveReply.conflict,
    }));

    const interruption: command_reply.ModelInterruptionTarget = .{ .session = session, .turn_id = max, .operation_id = max };
    try std.testing.expectEqual(protocol.model_interruption_reply.max_bytes, try Worst.reply(renderModelInterruptionReply, interruption, .{
        command_reply.ModelInterruptionReply{ .accepted = .{ .replayed = false } },
        command_reply.ModelInterruptionReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.ModelInterruptionRejection) } },
        command_reply.ModelInterruptionReply.conflict,
    }));

    const decision: PermissionTarget = .{ .session = session, .action_id = max, .decision = Worst.tag(protocol.PermissionDecision) };
    try std.testing.expectEqual(protocol.permission_decision_reply.max_bytes, try Worst.reply(renderPermissionDecisionReply, decision, .{
        command_reply.PermissionDecisionReply{ .accepted = .{ .replayed = false } },
        command_reply.PermissionDecisionReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.PermissionDecisionRejection) } },
        command_reply.PermissionDecisionReply.conflict,
    }));

    var failure: protocol.ResponseBuffer = .{};
    try failure.render(renderStatic, .{ Worst.tag(protocol.ErrorType), &escaped_code });
    try std.testing.expectEqual(protocol.max_control_error_response_bytes, failure.len);

    var host_info: protocol.ResponseBuffer = .{};
    const worst_info: HostInfo = .{ .store = &escaped_store, .instance = @splat(0xff), .active_capacity = max, .intake_capacity = max, .descriptor_soft_limit = max, .started_at = max, .custody_occupied = max, .paused = false, .routes = protocol.routesAll(.chatgpt_device), .doublewrite = null };
    try host_info.render(renderHostInfo, .{worst_info});
    const shape = protocol.host_info_reply;
    try std.testing.expectEqual(protocol.shapeBytes(shape.head) + protocol.shapeBytes(shape.tail), host_info.len);
    host_info.len = 0;
    var with_diagnostic = worst_info;
    // The public shape permits the full selector bound and the optional
    // diagnostic together, not just a MySQL id's narrower runtime bound.
    with_diagnostic.doublewrite = &@as([32]u8, @splat(0x01));
    try host_info.render(renderHostInfo, .{with_diagnostic});
    try std.testing.expectEqual(protocol.max_host_info_response_bytes, host_info.len);

    const observations = protocol.command_observation_reply;
    var configured = command_reply.CommandObservation{ .status = .accepted, .code = code, .kind = .{ .configure = .{ .revision = max, .created = false } } };
    try configured.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.configure), try Worst.observation(&escaped_key, configured));

    // Message's full live work plus four recovery descriptions is exercised
    // separately above; each closed result shape is checked byte-exactly.
    var stopped = command_reply.CommandObservation{ .status = .accepted, .code = code, .kind = .{ .session_stop = .{
        .selection = .{ .selected_turn_id = max, .admission_cutoff = max },
        .completion = Worst.tag(protocol.SessionStopCompletion),
    } } };
    try stopped.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.session_stop), try Worst.observation(&escaped_key, stopped));

    var archived = command_reply.CommandObservation{ .status = .accepted, .code = code, .kind = .{ .session_archive = .{
        .archived = false,
        .completion = Worst.tag(protocol.SessionStopCompletion),
    } } };
    try archived.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.session_archive), try Worst.observation(&escaped_key, archived));

    var interrupted = command_reply.CommandObservation{ .status = .accepted, .code = code, .kind = .{ .model_interruption = .{
        .session = session,
        .turn_id = max,
        .operation_id = max,
    } } };
    try interrupted.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.model_interruption), try Worst.observation(&escaped_key, interrupted));

    var decided = command_reply.CommandObservation{ .status = .accepted, .code = code, .kind = .{ .permission_decision = .{ .action_id = max, .decision = Worst.tag(protocol.PermissionDecision) } } };
    try decided.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.permission_decision), try Worst.observation(&escaped_key, decided));
    try std.testing.expect(try Worst.observation(&escaped_key, .{ .status = .absent }) <= protocol.command_observation_reply.max_bytes);

    var description: protocol.Bounded(protocol.max_tool_description_bytes) = .{};
    try description.set(&@as([protocol.max_tool_description_bytes]u8, @splat(1)));
    var label: protocol.Bounded(protocol.max_label_bytes) = .{};
    try label.set(&@as([protocol.max_label_bytes]u8, @splat(1)));
    var bash_description: protocol.Bounded(protocol.session_work.max_description_bytes) = .{};
    try bash_description.set(&@as([protocol.session_work.max_description_bytes]u8, @splat(1)));
    const presentation: protocol.ToolPresentation = .{ .description = description, .code = Worst.tag(protocol.ToolPresentation.Code), .publication_position = max };
    var longest_conversation: usize = 0;
    for (std.meta.tags(protocol.ConversationItemKind)) |kind| {
        var page: command_reply.PublicConversationPage = .{ .end = max, .count = protocol.public_conversation_page_items, .more = true };
        for (&page.items) |*item| item.* = .{
            .position = max,
            .ordinal = max,
            .kind = kind,
            .content = content,
            .presentation = if (kind == .tool_result or kind == .hosted_call) presentation else null,
            .admitted_at = if (kind == .user) max else null,
            .sender = if (kind == .user) .{ .session = session, .label = label } else null,
        };
        var response: protocol.FixedJsonBuffer(protocol.max_conversation_page_response_bytes) = .{};
        try response.render(renderConversationPage, .{&page});
        longest_conversation = @max(longest_conversation, response.len);
    }
    try std.testing.expectEqual(protocol.max_conversation_page_response_bytes, longest_conversation);

    var key: protocol.Bounded(protocol.max_key_bytes) = .{};
    try key.set(&escaped_key);
    const peer: protocol.NamedPeer = .{ .session = session, .label = label };
    const reference: protocol.ActivityItem.Content = .{ .length = max, .digest = content.digest };
    const field: protocol.ProposalFieldReference = .{ .length = max, .digest = content.digest };
    const values = [_]protocol.ActivityItem.Value{
        .{ .admission = .{ .admission = max, .key = key, .turn = max, .state = Worst.tag(@FieldType(protocol.ActivityItem.Message, "state")), .content = reference, .admitted_at = max, .sender = peer } },
        .{ .user = .{ .admission = max, .key = key, .turn = max, .state = Worst.tag(@FieldType(protocol.ActivityItem.Message, "state")), .content = reference, .admitted_at = max, .sender = peer } },
        .{ .assistant = .{ .content = reference, .final = false } },
        .{ .call = .{ .position = max, .operation = max, .turn = max, .call_ordinal = max, .action = max, .rejection = Worst.tag(protocol.ProposalRejection), .fields = @splat(field), .description = .{ .bytes = @splat(1), .len = protocol.max_tool_description_bytes }, .tool = .{ .bytes = @splat(1), .len = @import("tool_name.zig").max_bytes }, .server = .{ .bytes = @splat(1), .len = @import("tool_record.zig").max_server_bytes } } },
        .{ .tool_result = .{ .content = reference, .presentation = presentation } },
        .{ .hosted_call = presentation },
        .{ .turn_ended = .{ .session = .{ .bytes = session.bytes[0..6].*, .len = 6 }, .turn = max, .operation = max, .ending = Worst.tag(protocol.TurnEnding), .code = code, .content = reference } },
        .{ .stop = .{ .key = key, .turn = max, .cutoff = max, .completion = Worst.tag(protocol.SessionStopCompletion) } },
        .{ .sent = .{ .admission = max, .target = peer, .content = reference, .admitted_at = max } },
        .{ .send_failed = .{ .key = key, .target = peer, .code = code } },
        .{ .received = .{ .admission = max, .key = key, .turn = max, .state = Worst.tag(@FieldType(protocol.ActivityItem.Message, "state")), .content = reference, .admitted_at = max, .sender = peer } },
        .{ .approval_requested = .{ .session = .{ .bytes = session.bytes[0..6].*, .len = 6 }, .action = max, .operation = max, .call_ordinal = max, .description = .{ .bytes = @splat(1), .len = protocol.max_tool_description_bytes }, .tool = .{ .bytes = @splat(1), .len = @import("tool_name.zig").max_bytes }, .server = .{ .bytes = @splat(1), .len = @import("tool_record.zig").max_server_bytes } } },
        .{ .session_changed = .{ .revision = max, .field = Worst.tag(protocol.SessionField), .provider_text = .{ .bytes = @splat(1), .len = protocol.max_report_bytes } } },
        .{ .compacted = .{ .operation = max, .dropped = max } },
        .{ .model_call = .{ .model = .{ .bytes = @splat(1), .len = protocol.max_model_bytes }, .served_model = .{ .bytes = @splat(1), .len = protocol.max_model_bytes }, .input_tokens = max, .output_tokens = max, .cached_tokens = max, .latency_ms = max, .first_event_ms = max, .status = code, .attempts = max } },
    };
    try std.testing.expectEqual(std.meta.tags(std.meta.Tag(protocol.ActivityItem.Value)).len, values.len);
    var longest_item: protocol.ActivityItem = undefined;
    var longest_item_bytes: usize = 0;
    for (values) |value| {
        const item: protocol.ActivityItem = .{ .position = max, .ordinal = max, .at = max, .value = value };
        var buffer: [activity_reply.ItemJson.max_json_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try (activity_reply.ItemJson{ .item = &item }).writeJson(&writer);
        if (writer.end > longest_item_bytes) {
            longest_item_bytes = writer.end;
            longest_item = item;
        }
    }
    try std.testing.expectEqual(activity_reply.ItemJson.max_json_bytes, longest_item_bytes);
    var facts: protocol.ActivityFacts = .{ .end = max, .direction = Worst.tag(@FieldType(protocol.ActivityPage, "direction")), .count = 16, .more = false };
    @memset(&facts.items, longest_item);
    facts.call_activity = .{ .total = max, .count = 3 };
    @memset(&facts.call_activity.entries, .{ .operation = max, .ordinal = max, .presentation = presentation });
    facts.queued = .{ .count = max, .oldest_position = max, .newest_admission = max, .newest_position = max };
    // The work state's longest kind: every variant written, the longest kept.
    var longest_state: protocol.WorkState = undefined;
    var longest_state_bytes: usize = 0;
    for ([_]protocol.WorkState{
        .{ .retrying = .{ .since = max, .due_at_ms = max, .cause = code, .attempt = max } },
        .{ .bash = .{ .since = max, .call = max, .description = bash_description, .running = max, .approvals = max } },
        .{ .failed = .{ .since = max, .code = code, .resets_at = max } },
        .{ .stopped = .{ .since = max, .cause = Worst.tag(protocol.session_work.StopCause) } },
        .{ .approval = .{ .since = max } },
    }) |state| {
        var buffer: [protocol.WorkStateJson.max_json_bytes]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try (protocol.WorkStateJson{ .state = state }).writeJson(&writer);
        if (writer.end > longest_state_bytes) {
            longest_state_bytes = writer.end;
            longest_state = state;
        }
    }
    try std.testing.expectEqual(protocol.WorkStateJson.max_json_bytes, longest_state_bytes);
    facts.work = .{
        .read_version = .{ .instance = @splat(255), .generation = std.math.maxInt(u64) },
        .work = .{ .state = longest_state, .turn = max, .operation = max, .first_action = max },
        .last_line = .{ .position = max, .text = .{ .bytes = @splat(1), .len = @import("session_list.zig").max_last_line_bytes } },
        .revision = max,
    };
    @memset(facts.work.workspace.bytes[0..protocol.max_workspace_bytes], 0x01);
    facts.work.workspace.len = protocol.max_workspace_bytes;
    var page_buffer: [activity_reply.max_page_bytes]u8 = undefined;
    var page_writer = std.Io.Writer.fixed(&page_buffer);
    try activity_reply.writeFullPage(&page_writer, &facts, &@as([change_ring.SessionToken.max_bytes]u8, @splat(1)));
    try std.testing.expectEqual(activity_reply.max_page_bytes, page_writer.end);

    const longest_name = @as([64]u8, @splat(1));
    const longest_description = @as([4096]u8, @splat(1));
    const suggestions: skill_suggestions.Page = .{
        .entries = &@as([skill_suggestions.capacity]skill_suggestions.Entry, @splat(.{ .name = &longest_name, .description = &longest_description })),
        .revision = max,
        .total = max,
    };
    var suggestions_response: protocol.FixedJsonBuffer(protocol.skill_suggestions_reply.max_bytes) = .{};
    try suggestions_response.render(renderSkillSuggestions, .{&suggestions});
    try std.testing.expectEqual(protocol.skill_suggestions_reply.max_bytes, suggestions_response.len);
}
