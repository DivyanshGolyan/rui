const std = @import("std");
const protocol = @import("protocol.zig");
const change_ring = @import("change_ring.zig");
const command_reply = @import("command_reply.zig");
const command_spec = @import("command_spec.zig");
const AttemptBinding = @import("attempt.zig").AttemptBinding;
const skill_suggestions = @import("skill_suggestions.zig");
const activity_reply = @import("activity_reply.zig");
const CallText = @import("activity_read.zig").CallText;

pub fn activityPageBytes(page: *const protocol.ActivityFacts) usize {
    return if (page.not_modified) protocol.shapeBytes(activity_reply.page_reply.unchanged) else activity_reply.max_page_bytes;
}

pub fn renderActivityPage(out: protocol.JsonOut, page: *const protocol.ActivityFacts) error{BufferTooLarge}!void {
    activity_reply.writePage(out.writer, page) catch return error.BufferTooLarge;
}

pub fn renderActivitySearch(out: protocol.JsonOut, page: *const protocol.ActivitySearchFacts) error{BufferTooLarge}!void {
    activity_reply.writeSearch(out.writer, page) catch return error.BufferTooLarge;
}

pub fn httpStatus(result: anytype) u16 {
    return switch (result) {
        .accepted, .rejected => 200,
        .conflict => 409,
        .infrastructure_failure => 500,
    };
}

pub fn renderConfigureReply(
    response: protocol.JsonOut,
    session: []const u8,
    result: command_reply.ConfigureReply,
) !void {
    const shapes = protocol.configuration_reply;
    try switch (result) {
        .accepted => |value| if (value.configuration) |config| response.appendShape(shapes.accepted_create, .{ value.replayed, value.session.slice(), value.revision, value.created, config.provider, config.model.slice(), config.reasoning_effort, config.workspace.slice(), @import("creation_receipt_wire.zig").NamesJson{ .value = config.tools.slice() }, @import("creation_receipt_wire.zig").NamesJson{ .value = config.loaded_tools.slice() }, config.permission_mode, config.compaction_trigger }) else if (value.skills) |status| response.appendShape(shapes.accepted_skills, .{ value.replayed, value.session.slice(), value.revision, status }) else response.appendShape(shapes.accepted, .{ value.replayed, value.session.slice(), value.revision, value.created }),
        .rejected => |value| renderToolRejection(response, session, value, shapes.rejected),
        .conflict => response.appendShape(shapes.conflict, .{session}),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

pub fn renderMessageReply(
    response: protocol.JsonOut,
    session: []const u8,
    result: command_reply.MessageReply,
) !void {
    const shapes = protocol.message_reply;
    try switch (result) {
        .accepted => |value| if (value.configuration) |config| response.appendShape(shapes.accepted_create, .{ value.replayed, value.session.slice(), value.admission_id, config.provider, config.model.slice(), config.reasoning_effort, config.workspace.slice(), @import("creation_receipt_wire.zig").NamesJson{ .value = config.tools.slice() }, @import("creation_receipt_wire.zig").NamesJson{ .value = config.loaded_tools.slice() }, config.permission_mode, config.compaction_trigger, protocol.MessageInputJson{ .value = value.content }, value.admission_id }) else response.appendShape(shapes.accepted, .{ value.replayed, value.session.slice(), value.admission_id, protocol.MessageInputJson{ .value = value.content }, value.admission_id }),
        .rejected => |value| switch (value.form) {
            .bytes => renderToolRejection(response, session, value, shapes.rejected),
            .parts => renderToolRejection(response, session, value, shapes.rejected_parts),
        },
        .conflict => response.appendShape(shapes.conflict, .{session}),
        .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
    };
}

noinline fn renderToolRejection(response: protocol.JsonOut, session: []const u8, value: anytype, comptime shape: anytype) !void {
    var buffer: [@import("tool_record.zig").HostToolSet.max_refusal_message_bytes]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const message: ?[]const u8 = if (value.message) |detail| message: {
        try detail.write(&writer);
        break :message writer.buffered();
    } else null;
    if (comptime @hasField(@TypeOf(value), "content")) {
        try response.appendShape(shape, .{ value.replayed, session, value.code, message, value.missing, value.content.length, value.content.digest });
    } else try response.appendShape(shape, .{ value.replayed, session, value.code, message, value.missing });
}

pub fn renderConversationPage(response: protocol.JsonOut, page: *const command_reply.PublicConversationPage) !void {
    const shapes = protocol.conversation_page_reply;
    try response.appendShape(shapes.head, .{page.end});
    for (page.items[0..page.count], 0..) |item, index| {
        if (index != 0) try response.append(",");
        switch (item.kind) {
            .hosted_call => try response.appendShape(shapes.hosted_call, .{ item.position, item.ordinal }),
            inline else => |kind| try response.appendShape(shapes.item(kind), .{ item.position, item.ordinal, protocol.ContentValueJson{ .value = item.content } }),
        }
        switch (item.kind) {
            .user => if (item.admitted_at) |second| try response.appendShape(shapes.admission, .{ second, protocol.NamedPeerJson.optional(item.sender), item.source_action }),
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

const SubjectTypes = struct {
    pub const model_interruption = command_reply.ModelInterruptionTarget;
    pub const permission_decision = struct {
        session: protocol.Bounded(protocol.max_session_bytes),
        action_id: u64,
        decision: protocol.PermissionDecision,
    };
    pub const action_stop = action_background;
    pub const action_background = struct {
        session: protocol.Bounded(protocol.max_session_bytes),
        action_id: u64,
    };
};

/// Concrete subject consumed by each mutation's typed reply renderer.
pub fn MutationSubject(comptime kind: command_spec.CommandKind) type {
    return command_spec.spec(kind).Subject(SubjectTypes);
}

/// Canonical Store result type for each mutation's typed reply renderer.
pub fn MutationResult(comptime kind: command_spec.CommandKind) type {
    return switch (kind) {
        .configure => command_reply.ConfigureReply,
        .message => command_reply.MessageReply,
        .session_stop => command_reply.SessionStopReply,
        .session_archive => command_reply.SessionArchiveReply,
        .session_pin => command_reply.SessionPinReply,
        .model_interruption => command_reply.ModelInterruptionReply,
        .permission_decision => command_reply.PermissionDecisionReply,
        .action_background => @import("action_control.zig").Reply,
        .action_stop => @import("action_control.zig").StopReply,
    };
}

/// Keeps every mutation's subject and Store result concrete at the call boundary.
pub fn renderMutationReply(comptime kind: command_spec.CommandKind) @TypeOf(switch (kind) {
    .configure => renderConfigureReply,
    .message => renderMessageReply,
    else => ControlRenderer(kind).render,
}) {
    return switch (kind) {
        .configure => renderConfigureReply,
        .message => renderMessageReply,
        else => ControlRenderer(kind).render,
    };
}

fn ControlRenderer(comptime kind: command_spec.CommandKind) type {
    const facts = command_spec.spec(kind);
    return struct {
        fn render(response: protocol.JsonOut, subject: MutationSubject(kind), result: MutationResult(kind)) !void {
            const shapes = facts.Reply(protocol);
            const target = switch (kind) {
                .session_stop, .session_archive, .session_pin => .{subject},
                .model_interruption => .{ subject.session.slice(), subject.turn_id, subject.operation_id },
                .permission_decision => .{ subject.session.slice(), subject.action_id, subject.decision },
                .action_background, .action_stop => .{ subject.session.slice(), subject.action_id },
                .configure, .message => unreachable,
            };
            try switch (result) {
                .accepted => |value| response.appendShape(shapes.accepted, .{value.replayed} ++ target ++ switch (kind) {
                    .session_stop => .{ value.selection.selected_turn_id, value.selection.admission_cutoff, value.completion },
                    .session_archive => .{ value.archived, value.completion },
                    .session_pin => .{value.pinned},
                    .model_interruption, .permission_decision => .{},
                    .action_background => .{ value.selection.kind, value.selection.position },
                    .action_stop => .{value.resolution},
                    .configure, .message => unreachable,
                }),
                .rejected => |value| response.appendShape(shapes.rejected, .{value.replayed} ++ target ++ .{value.code}),
                .conflict => response.appendShape(shapes.conflict, target),
                .infrastructure_failure => renderStatic(response, .invocation_error, "canonical_store_failure"),
            };
        }
    };
}

pub fn renderActionRead(response: protocol.JsonOut, value: *const @import("action_read.zig").Read) !void {
    const shapes = protocol.action_read_reply;
    try response.appendShape(shapes.head, .{ value.session.slice(), value.action_id });
    switch (value.status) {
        .pending => |state| try response.appendShape(shapes.pending, .{state}),
        .resolved => |*final| try response.appendShape(shapes.final, .{ final.resolution.position, final.resolution.code.slice(), protocol.ContentValueJson{ .value = final.resolution.content }, final.window.offset, final.window.next, final.window.more, final.window.text.slice() }),
        .resolved_parts => |*final| try response.appendShape(shapes.parts, .{ final.position, final.code.slice(), protocol.ContentValueJson{ .value = final.content } }),
    }
    try response.writer.writeAll(shapes.values_head);
    try response.writer.writeByte('[');
    for (value.values.items[0..value.values.count], 0..) |item, index| {
        if (index != 0) try response.writer.writeByte(',');
        try response.appendShape(shapes.item, .{ item.ordinal, item.key.slice(), value.values.bytes[item.start..][0..item.length] });
    }
    try response.writer.writeByte(']');
    try response.appendShape(shapes.values_tail, .{ value.values.next, value.values.more });
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
        .message => |*maybe_message| if (observation.status == .accepted) {
            const message = if (maybe_message.*) |*value| value else return error.InvalidCommandObservation;
            const accepted = message.queue orelse return error.InvalidCommandObservation;
            try response.appendShape(shapes.input, .{protocol.MessageInputJson{ .value = message.content }});
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
                    const wire: protocol.SessionWork = .fromCore(work);
                    try response.appendShape(shapes.work, .{ protocol.WorkStateJson{ .state = work.state }, work.first_action } ++ wire.extraArgs());
                },
            }
            if (message.recovery.count != 0) try response.appendShape(shapes.recovery, .{protocol.MessageRecoveryJson{
                .calls = message.recovery.calls[0..message.recovery.count],
                .more = message.recovery.more,
            }});
        },
        .session_stop => |maybe_stop| if (maybe_stop) |stop| try response.appendShape(shapes.session_stop, .{ stop.selection.selected_turn_id, stop.selection.admission_cutoff, stop.completion }),
        .session_pin => |pin| if (pin) |value| try response.appendShape(shapes.session_pin, .{value.pinned}),
        .session_archive => |archive| if (archive) |value| try response.appendShape(shapes.session_archive, .{ value.archived, value.completion }),
        .model_interruption => |target| try response.appendShape(shapes.model_interruption, .{ target.session.slice(), target.turn_id, target.operation_id }),
        .permission_decision => |permission| try response.appendShape(shapes.permission_decision, .{ permission.action_id, permission.decision }),
        .action_stop => |selected| {
            try response.appendShape(shapes.action_target, .{selected.action_id});
            if (observation.status == .accepted) try response.appendShape(shapes.action_stop, .{selected.resolution});
        },
        .action_background => |selected| {
            try response.appendShape(shapes.action_target, .{selected.action_id});
            if (selected.selection) |selection| try response.appendShape(shapes.action_selection, .{ selection.kind, selection.position });
        },
    }
    try response.appendShape(shapes.tail, .{});
}

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
    /// SHA-256 of the frozen settings frame a detached Host started with; null for a foreground Host.
    settings_digest: ?@import("host_settings_handoff.zig").Digest,
};

pub fn renderHostInfo(response: protocol.JsonOut, info: HostInfo) !void {
    var digits: [protocol.Hole.maxBytes(.decimal)]u8 = undefined;
    const limit_text = if (info.descriptor_soft_limit) |limit| std.fmt.bufPrint(&digits, "{d}", .{limit}) catch unreachable else "unlimited";
    const routes = info.routes;
    const shape = protocol.host_info_reply;
    try response.appendShape(shape.head, .{ info.store, info.instance, info.active_capacity, info.intake_capacity, limit_text, info.started_at, info.custody_occupied, info.paused });
    if (info.doublewrite) |value| try response.appendShape(shape.doublewrite, .{value});
    if (info.settings_digest) |digest| try response.appendShape(shape.settings_digest, .{digest});
    try response.appendShape(shape.tail, .{ routes.codex, routes.openai, routes.chatgpt });
}

pub fn renderHostPause(response: protocol.JsonOut, paused: bool) !void {
    try response.appendShape(protocol.host_pause_reply, .{paused});
}

pub fn renderHostDrain(response: protocol.JsonOut, until_unix_ms: u64) !void {
    try response.appendShape(protocol.host_drain_reply, .{until_unix_ms});
}

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

pub const ToolAsk = struct { server: []const u8, generation: u64 };

pub fn renderToolsReload(response: protocol.JsonOut, asked: []const ToolAsk) error{BufferTooLarge}!void {
    try response.appendShape(protocol.tools_reload_reply.head, .{});
    for (asked, 0..) |ask, index| {
        if (index != 0) try response.append(",");
        try response.appendShape(protocol.tools_reload_reply.entry, .{ ask.server, ask.generation });
    }
    try response.append(protocol.tools_reload_reply.tail);
}

pub const ToolServerStatus = struct { server: []const u8, status: @import("mcp/relist.zig").Status };

pub fn renderToolsStatus(response: protocol.JsonOut, servers: []const ToolServerStatus) error{BufferTooLarge}!void {
    try response.appendShape(protocol.tools_status_reply.head, .{});
    for (servers, 0..) |row, index| {
        if (index != 0) try response.append(",");
        try response.appendShape(protocol.tools_status_reply.entry, .{ row.server, row.status.state, row.status.last, row.status.finished, row.status.tools });
    }
    try response.append(protocol.tools_status_reply.tail);
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
    const max = std.math.maxInt(u64);
    const escaped_session = @as([protocol.max_session_bytes]u8, @splat(1));
    const escaped_key = @as([protocol.max_key_bytes]u8, @splat(1));
    const escaped_code = @as([protocol.max_code_bytes]u8, @splat(1));
    const escaped_store = @as([protocol.max_store_bytes]u8, @splat(1));
    const content: command_reply.ContentReference = .{ .length = max, .digest = @splat(0xff) };
    const parts: protocol.content_value.Value = .{ .parts = .{ .identity = content, .owner = .{ .message = max } } };
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try session.set(&escaped_session);
    var code: protocol.Bounded(protocol.max_code_bytes) = .{};
    try code.set(&escaped_code);
    const Worst = struct {
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

    var config: command_reply.CreationConfiguration = .{
        .provider = Worst.tag(protocol.Provider),
        .model = .{},
        .reasoning_effort = Worst.tag(protocol.ReasoningEffort),
        .workspace = .{},
        .tools = .{},
        .loaded_tools = .{},
        .permission_mode = Worst.tag(@import("cli_value.zig").PermissionMode),
        .compaction_trigger = max,
    };
    try config.model.set(&@as([protocol.max_model_bytes]u8, @splat(1)));
    try config.workspace.set(&@as([protocol.max_workspace_bytes]u8, @splat(1)));
    var names: [protocol.max_tool_names_bytes]u8 = @splat('x');
    for (0..127) |i| names[32 + i * 33] = ',';
    try config.tools.set(&names);
    try config.loaded_tools.set(&names);
    const message_expansion = protocol.Hole.maxBytes(.{ .optional_string = @import("tool_record.zig").HostToolSet.max_refusal_message_bytes }) - "null".len +
        @import("required_settings.zig").Missing.max_json_bytes - "null".len;
    try std.testing.expectEqual(protocol.configuration_reply.max_bytes, @max(
        try Worst.reply(renderMutationReply(.configure), @as([]const u8, &escaped_session), .{
            command_reply.ConfigureReply{ .accepted = .{ .replayed = false, .revision = max, .created = false, .session = session, .skills = .unchanged } },
            command_reply.ConfigureReply{ .accepted = .{ .replayed = false, .revision = max, .created = false, .session = session, .configuration = &config } },
            command_reply.ConfigureReply.conflict,
        }),
        try Worst.reply(renderMutationReply(.configure), @as([]const u8, &escaped_session), .{
            command_reply.ConfigureReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.ConfigurationRejection) } },
        }) + message_expansion,
    ));

    try std.testing.expectEqual(protocol.message_reply.max_bytes, @max(
        try Worst.reply(renderMutationReply(.message), @as([]const u8, &escaped_session), .{
            command_reply.MessageReply{ .accepted = .{ .replayed = false, .admission_id = max, .content = .{ .text = content }, .session = session } },
            command_reply.MessageReply{ .accepted = .{ .replayed = false, .admission_id = max, .content = parts, .session = session } },
            command_reply.MessageReply{ .accepted = .{ .replayed = false, .admission_id = max, .content = .{ .text = content }, .session = session, .configuration = &config } },
            command_reply.MessageReply{ .accepted = .{ .replayed = false, .admission_id = max, .content = parts, .session = session, .configuration = &config } },
            command_reply.MessageReply.conflict,
        }),
        try Worst.reply(renderMutationReply(.message), @as([]const u8, &escaped_session), .{
            command_reply.MessageReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.MessageRejection), .content = content } },
            command_reply.MessageReply{ .rejected = .{ .form = .parts, .replayed = false, .code = Worst.tag(protocol.MessageRejection), .content = content } },
        }) + message_expansion,
    ));

    try std.testing.expectEqual(protocol.shapeBytes(protocol.configuration_reply.accepted_create), protocol.configuration_reply.max_bytes);
    try std.testing.expectEqual(protocol.shapeBytes(protocol.message_reply.accepted_create), protocol.message_reply.max_bytes);

    try std.testing.expectEqual(protocol.session_stop_reply.max_bytes, try Worst.reply(renderMutationReply(.session_stop), @as([]const u8, &escaped_session), .{
        command_reply.SessionStopReply{ .accepted = .{ .replayed = false, .selection = .{ .selected_turn_id = max, .admission_cutoff = max }, .completion = Worst.tag(protocol.SessionStopCompletion) } },
        command_reply.SessionStopReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.SessionStopRejection) } },
        command_reply.SessionStopReply.conflict,
    }));

    try std.testing.expectEqual(protocol.session_archive_reply.max_bytes, try Worst.reply(renderMutationReply(.session_archive), @as([]const u8, &escaped_session), .{
        command_reply.SessionArchiveReply{ .accepted = .{ .replayed = false, .archived = false, .completion = Worst.tag(protocol.SessionStopCompletion) } },
        command_reply.SessionArchiveReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.SessionArchiveRejection) } },
        command_reply.SessionArchiveReply.conflict,
    }));

    try std.testing.expectEqual(protocol.session_pin_reply.max_bytes, try Worst.reply(renderMutationReply(.session_pin), @as([]const u8, &escaped_session), .{
        command_reply.SessionPinReply{ .accepted = .{ .replayed = false, .pinned = false } },
        command_reply.SessionPinReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.SessionPinRejection) } },
        command_reply.SessionPinReply.conflict,
    }));

    const interruption: command_reply.ModelInterruptionTarget = .{ .session = session, .turn_id = max, .operation_id = max };
    try std.testing.expectEqual(protocol.model_interruption_reply.max_bytes, try Worst.reply(renderMutationReply(.model_interruption), interruption, .{
        command_reply.ModelInterruptionReply{ .accepted = .{ .replayed = false } },
        command_reply.ModelInterruptionReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.ModelInterruptionRejection) } },
        command_reply.ModelInterruptionReply.conflict,
    }));

    const decision: MutationSubject(.permission_decision) = .{ .session = session, .action_id = max, .decision = Worst.tag(protocol.PermissionDecision) };
    try std.testing.expectEqual(protocol.permission_decision_reply.max_bytes, try Worst.reply(renderMutationReply(.permission_decision), decision, .{
        command_reply.PermissionDecisionReply{ .accepted = .{ .replayed = false } },
        command_reply.PermissionDecisionReply{ .rejected = .{ .replayed = false, .code = Worst.tag(protocol.PermissionDecisionRejection) } },
        command_reply.PermissionDecisionReply.conflict,
    }));

    const background: MutationSubject(.action_background) = .{ .session = session, .action_id = max };
    const control = @import("action_control.zig");
    try std.testing.expectEqual(protocol.action_background_reply.max_bytes, try Worst.reply(renderMutationReply(.action_background), background, .{
        control.Reply{ .accepted = .{ .replayed = false, .action_id = max, .selection = .{ .kind = Worst.tag(@FieldType(control.Selection, "kind")), .position = max } } },
        control.Reply{ .rejected = .{ .replayed = false, .code = Worst.tag(control.Rejection) } },
        control.Reply.conflict,
    }));

    var failure: protocol.ResponseBuffer = .{};
    try failure.render(renderStatic, .{ Worst.tag(protocol.ErrorType), &escaped_code });
    try std.testing.expectEqual(protocol.max_control_error_response_bytes, failure.len);

    var host_info: protocol.ResponseBuffer = .{};
    const worst_info: HostInfo = .{ .store = &escaped_store, .instance = @splat(0xff), .active_capacity = max, .intake_capacity = max, .descriptor_soft_limit = max, .started_at = max, .custody_occupied = max, .paused = false, .routes = protocol.routesAll(.chatgpt_device), .doublewrite = null, .settings_digest = null };
    try host_info.render(renderHostInfo, .{worst_info});
    const shape = protocol.host_info_reply;
    try std.testing.expectEqual(protocol.shapeBytes(shape.head) + protocol.shapeBytes(shape.tail), host_info.len);
    host_info.len = 0;
    var with_diagnostic = worst_info;
    with_diagnostic.doublewrite = &@as([32]u8, @splat(0x01));
    with_diagnostic.settings_digest = @splat(0xff);
    try host_info.render(renderHostInfo, .{with_diagnostic});
    try std.testing.expectEqual(protocol.max_host_info_response_bytes, host_info.len);

    const observations = protocol.command_observation_reply;
    const message: command_reply.CommandObservation = .{ .status = .accepted, .target = session, .kind = .{ .message = .{
        .content = parts,
        .queue = .{ .admission_id = max, .state = .queued },
        .admitted_at = max,
        .work = .{ .state = .{ .pending = .{ .since = max } } },
    } } };
    try std.testing.expect(try Worst.observation(&escaped_key, message) <= observations.maxBytes(.message));
    var input_storage: [protocol.MessageInputJson.max_json_bytes]u8 = undefined;
    var input_writer = std.Io.Writer.fixed(&input_storage);
    try (protocol.MessageInputJson{ .value = parts }).writeJson(&input_writer);
    try std.testing.expectEqual(input_storage.len, input_writer.buffered().len);

    var configured = command_reply.CommandObservation{ .status = .accepted, .code = code, .kind = .{ .configure = .{ .revision = max, .created = false } } };
    try configured.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.configure), try Worst.observation(&escaped_key, configured));

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
    var backgrounded = command_reply.CommandObservation{ .status = .accepted, .code = code, .kind = .{ .action_background = .{
        .action_id = max,
        .selection = .{ .kind = Worst.tag(@FieldType(control.Selection, "kind")), .position = max },
    } } };
    try backgrounded.target.set(&escaped_session);
    try std.testing.expectEqual(observations.maxBytes(.action_background), try Worst.observation(&escaped_key, backgrounded));
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
            .content = .{ .parts = .{ .identity = content, .owner = .{ .message = max } } },
            .presentation = if (kind == .tool_result or kind == .hosted_call) presentation else null,
            .admitted_at = if (kind == .user) max else null,
            .sender = if (kind == .user) .{ .session = session, .label = label } else null,
            .source_action = if (kind == .user) max else null,
        };
        var response: protocol.FixedJsonBuffer(protocol.max_conversation_page_response_bytes) = .{};
        try response.render(renderConversationPage, .{&page});
        longest_conversation = @max(longest_conversation, response.len);
    }
    try std.testing.expectEqual(protocol.max_conversation_page_response_bytes, longest_conversation);

    var key: protocol.Bounded(protocol.max_key_bytes) = .{};
    try key.set(&escaped_key);
    const peer: protocol.NamedPeer = .{ .session = session, .label = label };
    const text: @import("content_value.zig").Reference = .{ .length = max, .digest = content.digest };
    const reference: @import("content_value.zig").Value = .{ .parts = .{ .identity = text, .owner = .{ .message = max } } };
    const field: protocol.ProposalFieldReference = .{ .length = max, .digest = content.digest };
    const values = [_]protocol.ActivityItem.Value{
        .{ .admission = .{ .admission = max, .key = key, .turn = max, .state = Worst.tag(@FieldType(protocol.ActivityItem.Message, "state")), .content = reference, .admitted_at = max, .sender = peer, .source_action = max } },
        .{ .user = .{ .admission = max, .key = key, .turn = max, .state = Worst.tag(@FieldType(protocol.ActivityItem.Message, "state")), .content = reference, .admitted_at = max, .sender = peer, .source_action = max } },
        .{ .assistant = .{ .content = text, .final = false } },
        .{ .call = .{ .position = max, .operation = max, .turn = max, .call_ordinal = max, .action = max, .rejection = Worst.tag(protocol.ProposalRejection), .fields = @splat(field), .description = .{ .bytes = @splat(1), .len = CallText.max_description_bytes }, .tool = .{ .bytes = @splat(1), .len = CallText.max_tool_bytes }, .server = .{ .bytes = @splat(1), .len = CallText.max_server_bytes } } },
        .{ .tool_result = .{ .content = reference, .presentation = presentation } },
        .{ .hosted_call = presentation },
        .{ .turn_ended = .{ .session = .{ .bytes = session.bytes[0..6].*, .len = 6 }, .turn = max, .operation = max, .ending = Worst.tag(protocol.TurnEnding), .code = code, .content = text } },
        .{ .stop = .{ .key = key, .turn = max, .cutoff = max, .completion = Worst.tag(protocol.SessionStopCompletion) } },
        .{ .sent = .{ .admission = max, .target = peer, .content = reference, .admitted_at = max } },
        .{ .send_failed = .{ .key = key, .target = peer, .code = code } },
        .{ .received = .{ .admission = max, .key = key, .turn = max, .state = Worst.tag(@FieldType(protocol.ActivityItem.Message, "state")), .content = reference, .admitted_at = max, .sender = peer, .source_action = max } },
        .{ .approval_requested = .{ .session = .{ .bytes = session.bytes[0..6].*, .len = 6 }, .action = max, .operation = max, .call_ordinal = max, .description = .{ .bytes = @splat(1), .len = CallText.max_description_bytes }, .tool = .{ .bytes = @splat(1), .len = CallText.max_tool_bytes }, .server = .{ .bytes = @splat(1), .len = CallText.max_server_bytes } } },
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
    facts.queued = .{ .count = max, .oldest_position = max, .newest_admission = max, .newest_position = max, .newest_content = .{ .parts = .{ .identity = .{ .length = max, .digest = @splat(0xff) }, .owner = .{ .message = max } } } };
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
        .creator = .{ .bytes = @splat(1), .len = protocol.session_id_bytes },
        .read_version = .{ .instance = @splat(255), .generation = std.math.maxInt(u64) },
        .work = .{ .state = longest_state, .turn = max, .operation = max, .first_action = max, .actions = .{ .stop = false, .interrupt = .{ .turn = max, .operation = max }, .decide = max }, .served_attention = .{ .kind = .approval, .turn = max, .step = max }, .served_group = .needs_you },
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

test "Action read JSON reaches its exact bound with an escaped final window" {
    // ARD-3
    const Read = @import("action_read.zig").Read;
    const value = try std.testing.allocator.create(Read);
    defer std.testing.allocator.destroy(value);
    const max = std.math.maxInt(u64);
    value.* = .{
        .session = .{ .bytes = @splat(1), .len = protocol.max_session_bytes },
        .action_id = max,
        .status = .{ .resolved = .{
            .resolution = .{ .position = max, .code = .{ .bytes = @splat(1), .len = protocol.max_code_bytes }, .content = .{ .parts = .{ .identity = .{ .length = max, .digest = @splat(0xff) }, .owner = .{ .message = max } } } },
            .window = .{ .offset = max, .next = max, .more = false, .text = .{ .bytes = @splat(1), .len = @import("action_read.zig").window_bytes } },
        } },
    };
    value.values.count = @import("action_read.zig").page_items;
    value.values.length = @import("action_read.zig").page_bytes;
    value.values.next = max;
    @memset(&value.values.bytes, 1);
    for (&value.values.items, 0..) |*item, i| {
        item.* = .{ .ordinal = max, .key = .{ .bytes = @splat(1), .len = 128 }, .start = 0, .length = if (i == 0) value.values.length else 0 };
    }
    const bytes = try std.testing.allocator.alloc(u8, protocol.action_read_reply.max_bytes);
    defer std.testing.allocator.free(bytes);
    var writer = std.Io.Writer.fixed(bytes);
    try renderActionRead(.{ .writer = &writer }, value);
    try std.testing.expectEqual(protocol.action_read_reply.max_bytes, writer.buffered().len);
    writer = .fixed(bytes);
    try renderActionRead(.{ .writer = &writer }, value);
    const decoded = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, writer.buffered(), .{});
    defer decoded.deinit();
    try std.testing.expectEqualStrings("resolved", decoded.value.object.get("state").?.string);
    const values = decoded.value.object.get("values").?.object;
    try std.testing.expectEqual(@as(usize, 16), values.get("items").?.array.items.len);
    try std.testing.expectEqualStrings("18446744073709551615", values.get("next").?.string);
    try std.testing.expect(!values.get("more").?.bool);
    const first = values.get("items").?.array.items[0].object;
    try std.testing.expectEqual(@as(usize, 16384), first.get("text").?.string.len);
    try std.testing.expectEqualSlices(u8, value.values.bytes[0..value.values.length], first.get("text").?.string);
    value.status = .{ .pending = .queued };
    writer = .fixed(bytes);
    try renderActionRead(.{ .writer = &writer }, value);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "\"final\":null,\"values\":") != null);
}

test "SH-60 Message replies and observations preserve the input form" {
    const identity: command_reply.ContentReference = .{ .length = 41, .digest = @splat(0xab) };
    const admission = 73;
    const digest = "abababababababababababababababababababababababababababababababab";
    var session: protocol.Bounded(protocol.max_session_bytes) = .{};
    try session.set("k7m2qx");
    const cases = .{
        .{ .form = .bytes, .content = @as(protocol.content_value.Value, .{ .text = identity }), .receipt = "\"input\":{\"type\":\"text\",\"bytes\":\"41\",\"sha256\":\"" ++ digest ++ "\"}", .suffix = "}" },
        .{ .form = .parts, .content = @as(protocol.content_value.Value, .{ .parts = .{ .identity = identity, .owner = .{ .message = admission } } }), .receipt = "\"input\":{\"type\":\"parts\",\"bytes\":\"41\",\"sha256\":\"" ++ digest ++ "\"}", .suffix = ",\"owner\":{\"message\":\"73\"}}" },
    };
    inline for (cases) |case| {
        var reply: protocol.ResponseBuffer = .{};
        try reply.render(renderMessageReply, .{ session.slice(), command_reply.MessageReply{ .accepted = .{
            .replayed = false,
            .admission_id = admission,
            .content = case.content,
            .session = session,
        } } });
        const accepted_input = case.receipt[0 .. case.receipt.len - 1] ++ case.suffix;
        try std.testing.expect(std.mem.indexOf(u8, reply.slice(), accepted_input ++ ",\"queue\":{\"status\":\"queued\",\"admission\":\"73\"}") != null);

        reply.len = 0;
        try reply.render(renderMessageReply, .{ session.slice(), command_reply.MessageReply{ .rejected = .{
            .form = case.form,
            .replayed = false,
            .code = .unknown_session,
            .content = identity,
        } } });
        try std.testing.expect(std.mem.indexOf(u8, reply.slice(), case.receipt) != null);

        const observation: command_reply.CommandObservation = .{ .status = .accepted, .target = session, .kind = .{ .message = .{
            .content = case.content,
            .queue = .{ .admission_id = admission, .state = .queued },
            .work = .{ .state = .{ .pending = .{ .since = 10 } } },
        } } };
        var response: protocol.CommandObservationBuffer = .{};
        try response.render(renderFullCommandObservation, .{ "key", &observation, null });
        try std.testing.expect(std.mem.indexOf(u8, response.slice(), accepted_input ++ ",\"queue\":{\"admission\":\"73\"") != null);
    }
    var rejected: command_reply.CommandObservation = .{ .status = .rejected, .target = session, .kind = .{ .message = null } };
    try rejected.code.set("unknown_session");
    var response: protocol.CommandObservationBuffer = .{};
    try response.render(renderFullCommandObservation, .{ "key", &rejected, null });
    try std.testing.expect(std.mem.endsWith(u8, response.slice(), "\"code\":\"unknown_session\",\"state\":\"rejected\"}}"));
}
