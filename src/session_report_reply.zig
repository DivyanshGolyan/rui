//! The `inspect-session` report: the Host writes the Session report the
//! Store reads (`store/domain/session_report_read.zig`) with the shapes
//! here, which also give the reply's schema (`openapi.zig`). The Full
//! profile's history is still written by the Store, into the same capture.
const std = @import("std");
const built_in_tool = @import("built_in_tool.zig");
const cli_value = @import("cli_value.zig");
const idempotency_key = @import("idempotency_key.zig");
const model_capability = @import("model_capability.zig");
const outcome_code = @import("outcome_code.zig");
const protocol = @import("protocol.zig");
const provider_name = @import("provider_name.zig");
const session_archive = @import("session_archive.zig");
const session_id = @import("session_id.zig");
const session_report = @import("session_report.zig");
const tool_name = @import("tool_name.zig");
const tool_presentation = @import("tool_presentation.zig");
const workspace_path = @import("workspace_path.zig");
const wire_version = @import("wire_version.zig").wire_version;
const H = protocol.Hole;

/// The visitor that writes one report into `capture`, a Session report
/// capture the caller created (`store.SessionReportCapture`), with the
/// Host's `execution` counters. Its tools buffer is over 4 KiB, so a server
/// allocates it and does not hold it on its stack.
pub fn Reply(comptime Capture: type) type {
    return struct {
        capture: *Capture,
        execution: session_report.Execution,
        actions: u64 = 0,
        rejected_calls: u64 = 0,
        first: bool = true,
        tools_json: [tool_name.max_names_json_bytes]u8 = undefined,

        pub fn missing(reply: *@This(), profile: cli_value.ReportProfile) !void {
            try reply.envelope(profile);
            try reply.capture.append(missing_text);
        }

        /// The envelope, the saved Session and the Current facts, up to the
        /// first list.
        pub fn current(reply: *@This(), profile: cli_value.ReportProfile, values: *const session_report.Current) !void {
            reply.actions = values.actions;
            reply.rejected_calls = values.rejected_calls;
            try reply.envelope(profile);
            try reply.capture.append(session_text);
            try reply.capture.appendShape(CurrentJson.Settings.head, .{
                values.reference,
                values.parent,
                values.workspace,
                values.provider,
                values.model,
                values.compaction_trigger,
                values.context_estimate,
                values.output_reservation,
                values.compaction_trigger_override,
                values.output_reservation_override,
                values.reasoning_effort,
                values.reasoning_effort_override,
                values.revision,
            });
            try reply.appendTools(values.tools);
            try reply.capture.append(CurrentJson.Settings.loaded_tools);
            try reply.appendTools(values.loaded_tools);
            try reply.capture.appendShape(CurrentJson.Settings.tail, .{
                values.permission_mode,
                reference(values.instructions),
                if (values.output_schema) |content| reference(content) else null,
                values.label,
                values.created_at,
            });
            try reply.capture.appendShape(after_settings, .{ values.archive_state, values.pending_messages });
            const work: protocol.SessionWork = .fromCore(values.work);
            try reply.capture.appendShape(CurrentJson.Work.head, work.args());
            if (values.latest_outcome) |outcome| {
                try reply.capture.appendShape(CurrentJson.Outcome.json_shape, .{ outcome.code, if (outcome.content) |content| reference(content) else null });
            } else try reply.capture.append("null");
            try reply.capture.append(CurrentJson.Work.tail);
            const peers: protocol.PeerFacts = .{ .from_person_at = values.peers.from_person_at };
            try reply.capture.appendShape(after_work, .{
                peers,
                if (values.first_message) |first| protocol.FirstMessage.fromCore(first) else null,
                values.selected_message,
            });
        }

        /// Ends the list before `list`, if any, and opens `list`.
        pub fn open(reply: *@This(), list: session_report.List) !void {
            reply.first = true;
            switch (list) {
                .recent_messages => try reply.capture.append("["),
                .unresolved_actions => try reply.capture.appendShape(.{ "],\"actions\":{\"count\":\"", H.decimal, "\",\"unresolved\":[" }, .{reply.actions}),
                .resolved_actions => try reply.capture.append("],\"resolved\":["),
                .rejected_calls => try reply.capture.appendShape(.{ "]},\"rejected_calls\":{\"count\":\"", H.decimal, "\",\"items\":[" }, .{reply.rejected_calls}),
                .actionable_permissions => try reply.capture.append("]},\"actionable_permissions\":["),
            }
        }

        pub fn row(reply: *@This(), values: *const session_report.Row) !void {
            if (!reply.first) try reply.capture.append(",");
            reply.first = false;
            const capture = reply.capture;
            switch (values.*) {
                .recent_messages => |recent| try capture.appendShape(CurrentJson.Recent.json_shape, .{ recent.turn, recent.message, recent.outcome }),
                .unresolved_actions => |action| {
                    try capture.appendShape(CurrentJson.Unresolved.head ++ .{H{ .json = ToolName }} ++ CurrentJson.Unresolved.authorization, .{
                        action.action,
                        action.parent_operation,
                        action.call_ordinal,
                        ToolName{ .name = action.tool },
                        action.permission_revision,
                        action.authorization,
                        TextReference.of(action.call_id),
                    });
                    if (action.server) |server| try capture.appendShape(CurrentJson.Unresolved.server, .{ToolName{ .name = server }});
                    try capture.appendShape(CurrentJson.Unresolved.tail, .{ TextReference.of(action.arguments), presentation(action.presentation) });
                },
                .resolved_actions => |action| try capture.appendShape(CurrentJson.Resolved.json_shape, .{
                    action.action,
                    action.parent_operation,
                    action.call_ordinal,
                    action.code,
                    action.acceptance_position,
                    TextReference.of(action.result),
                    presentation(action.presentation),
                }),
                .rejected_calls => |call| try capture.appendShape(CurrentJson.Rejected.json_shape, .{
                    call.parent_operation,
                    call.call_ordinal,
                    call.code,
                    call.acceptance_position,
                    TextReference.of(call.result),
                    TextReference.of(call.name),
                    TextReference.of(call.call_id),
                    TextReference.of(call.arguments),
                    presentation(call.presentation),
                }),
                .actionable_permissions => |action| try capture.appendShape(CurrentJson.Actionable.json_shape, .{ action.action, action.permission_revision }),
            }
        }

        /// Ends the last list and the Current facts.
        pub fn end(reply: *@This()) !void {
            try reply.capture.append("]");
        }

        /// The Host's execution counters, which close the report.
        pub fn tail(reply: *@This()) !void {
            const execution = reply.execution;
            try reply.capture.appendShape(shapes.tail_text ++ ExecutionJson.json_shape ++ .{"}"}, .{ execution.dispatch_fenced, execution.custody_occupied, execution.scratch_used_bytes });
        }

        fn envelope(reply: *@This(), profile: cli_value.ReportProfile) !void {
            // Host-global execution counters and retry clocks are not
            // Session-token facts.
            try reply.capture.append(switch (profile) {
                .current => shapes.current_head[0],
                .full => shapes.head[0],
            });
            try reply.capture.append(@tagName(profile));
        }

        fn appendTools(reply: *@This(), names: []const []const u8) !void {
            var tools = std.Io.Writer.fixed(&reply.tools_json);
            try tool_name.writeNamesJson(&tools, names);
            try reply.capture.append(tools.buffered());
        }
    };
}

fn reference(content: session_report.Content) Reference {
    return .{ .length = content.length, .digest = content.digest };
}

fn presentation(value: tool_presentation.ToolPresentation) protocol.ToolPresentationJson {
    return .{ .value = value };
}

const session_text = "\",\"session\":";
const missing_text = "\",\"session\":null,\"pending_messages\":\"0\",\"execution\":{\"status\":\"unavailable\",\"reason\":\"session_not_found\"}}";

/// The Current facts between the saved Session and the work.
const after_settings = .{ ",\"archive_state\":\"", H{ .tag = session_archive.State }, "\",\"pending_messages\":\"", H.decimal, "\",\"work\":" };

/// The Current facts between the work and the first list.
const after_work = .{ ",\"peers\":", H{ .json = protocol.PeerFacts }, ",\"first_message\":", H{ .optional_json = protocol.FirstMessage }, ",\"selected_message\":", H{ .optional_string = idempotency_key.max_bytes }, ",\"recent_messages\":" };

/// Wire shapes of the report envelope. Full history is present only for
/// the full profile; its shape is the Store's (`store.SessionReportFull`)
/// until the Host writes it, so `openapi.zig` places it between `full_head`
/// and `tail`.
pub const shapes = struct {
    const head = .{"{\"version\":\"" ++ wire_version ++ "\",\"type\":\"session_report\",\"profile\":\""};
    const current_head = .{"{\"version\":\"" ++ wire_version ++ "\",\"type\":\"session_report\",\"delta\":\"full\",\"since\":null,\"profile\":\""};
    const facts = .{ session_text, H{ .json = CurrentJson.Settings } } ++ after_settings ++ .{H{ .json = CurrentJson.Work }} ++ after_work ++
        .{ ListOf(CurrentJson.Recent), ",\"actions\":", H{ .json = CurrentJson.Actions }, ",\"rejected_calls\":", H{ .json = CurrentJson.RejectedCalls }, ",\"actionable_permissions\":", ListOf(CurrentJson.Actionable) };
    const tail_text = .{",\"execution\":"};
    pub const tail = tail_text ++ .{ H{ .json = ExecutionJson }, "}" };
    pub const current = current_head ++ .{"current"} ++ facts ++ tail;
    pub const full_head = head ++ .{"full"} ++ facts;
    pub const missing_current = current_head ++ .{"current" ++ missing_text};
    pub const missing_full = head ++ .{"full" ++ missing_text};
};

fn ListOf(comptime T: type) type {
    return struct {
        pub const openapi_list = T;
    };
}

/// Execution counters are supplied by the Host, not read from the Store.
pub const ExecutionJson = struct {
    pub const openapi_name = "domainreportExecutionJson";
    pub const json_shape = .{ "{\"status\":\"partial\",\"dispatch_fenced\":", H.boolean, ",\"custody_occupied\":\"", H.decimal, "\",\"scratch_used_bytes\":\"", H.decimal, "\",\"unavailable\":[\"structured_output\"]}" };
};

const Reference = protocol.ActivityItem.Content;

/// A content reference typed as text.
pub const TextReference = struct {
    length: u64,
    digest: [32]u8,

    pub const openapi_name = "domainreportCurrentJsonTextReference";
    pub const json_shape = protocol.content_reference_shape;
    pub const max_json_bytes = protocol.shapeBytes(json_shape);

    fn of(content: session_report.Content) TextReference {
        return .{ .length = content.length, .digest = content.digest };
    }

    pub fn writeJson(self: *const TextReference, out: *std.Io.Writer) !void {
        try protocol.writeShape(out, json_shape, .{ self.length, self.digest });
    }
};

/// A tool's name (`tool_name.valid`), as a JSON string.
pub const ToolName = struct {
    name: []const u8,

    pub const openapi_tool_name = true;
    pub const max_json_bytes = tool_name.max_bytes + 2;

    pub fn writeJson(self: *const ToolName, out: *std.Io.Writer) !void {
        std.debug.assert(tool_name.valid(self.name));
        try out.writeByte('"');
        try out.writeAll(self.name);
        try out.writeByte('"');
    }
};

/// The Current report's own parts. Shared work, peer, Message and
/// presentation fields use their wire types' shapes rather than a second
/// description here. The `openapi_name`s keep the schema names these had
/// when the Store wrote them.
pub const CurrentJson = struct {
    const ToolNames = struct {
        pub const openapi_tools = true;
    };
    pub const Settings = struct {
        pub const openapi_name = "domainreportCurrentJsonSettings";
        const head = .{
            "{\"reference\":",                     H{ .string = session_id.max_reference_bytes },
            ",\"parent\":",                        H{ .optional_string = session_id.bytes },
            ",\"workspace\":",                     H{ .string = workspace_path.max_bytes },
            ",\"provider\":\"",                    H{ .tag = provider_name.Provider },
            "\",\"model\":",                       H{ .string = model_capability.max_model_bytes },
            ",\"compaction_trigger\":\"",          H.decimal,
            "\",\"context_estimate\":",            H.optional_id,
            ",\"output_reservation\":\"",          H.decimal,
            "\",\"compaction_trigger_override\":", H.optional_id,
            ",\"output_reservation_override\":",   H.optional_id,
            ",\"reasoning_effort\":",              H{ .optional_tag = model_capability.ReasoningEffort },
            ",\"reasoning_effort_override\":",     H{ .optional_tag = model_capability.ReasoningEffort },
            ",\"revision\":\"",                    H.decimal,
            "\",\"tools\":",
        };
        const loaded_tools = ",\"loaded_tools\":";
        const tail = .{
            ",\"permission_mode\":\"", H{ .tag = cli_value.PermissionMode },
            "\",\"instructions\":",    H{ .json = Reference },
            ",\"output_schema\":",     H{ .optional_json = Reference },
            ",\"label\":",             H{ .optional_string = tool_presentation.max_label_bytes },
            ",\"created_at\":\"",      H.decimal,
            "\"}",
        };
        pub const json_shape = head ++ .{ ToolNames, loaded_tools, ToolNames } ++ tail;
    };
    pub const Outcome = struct {
        pub const openapi_name = "domainreportCurrentJsonOutcome";
        pub const json_shape = .{ "{\"code\":", H{ .string = outcome_code.max_bytes }, ",\"content\":", H{ .optional_json = Reference }, "}" };
    };
    pub const Work = struct {
        pub const openapi_name = "domainreportCurrentJsonWork";
        const head = .{"{"} ++ protocol.SessionWork.fields ++ .{",\"latest_outcome\":"};
        const tail = "}";
        pub const json_shape = head ++ .{ H{ .optional_json = Outcome }, tail };
    };
    pub const Recent = struct {
        pub const openapi_name = "domainreportCurrentJsonRecent";
        pub const json_shape = .{ "{\"turn\":\"", H.decimal, "\",\"message\":", H{ .string = idempotency_key.max_bytes }, ",\"outcome\":", H{ .string = outcome_code.max_bytes }, "}" };
    };
    /// A built-in call names its tool; an MCP call names an MCP tool and
    /// its server.
    pub const Unresolved = struct {
        pub const openapi_name = "domainreportCurrentJsonUnresolved";
        const head = .{ "{\"action\":\"", H.decimal, "\",\"parent_operation\":\"", H.decimal, "\",\"call_ordinal\":\"", H.decimal, "\",\"tool\":" };
        const authorization = .{ ",\"permission_revision\":\"", H.decimal, "\",\"authorization\":\"", H{ .tag = session_report.Authorization }, "\",\"call_id\":", H{ .json = TextReference } };
        const server = .{ ",\"server\":", H{ .json = ToolName } };
        const tail = .{ ",\"arguments\":", H{ .json = TextReference }, ",\"presentation\":", H{ .json = protocol.ToolPresentationJson }, "}" };
        pub const openapi_shapes = .{
            head ++ .{ "\"", H{ .tag = built_in_tool.BuiltInTool }, "\"" } ++ authorization ++ tail,
            head ++ .{H{ .json = ToolName }} ++ authorization ++ server ++ tail,
        };
    };
    pub const Resolved = struct {
        pub const openapi_name = "domainreportCurrentJsonResolved";
        /// The Store checks that a resolved Action's code names a
        /// presentation code.
        const max_code_bytes = maxTagBytes(tool_presentation.ToolPresentation.Code);
        pub const json_shape = .{ "{\"action\":\"", H.decimal, "\",\"parent_operation\":\"", H.decimal, "\",\"call_ordinal\":\"", H.decimal, "\",\"code\":", H{ .string = max_code_bytes }, ",\"acceptance_position\":\"", H.decimal, "\",\"result\":", H{ .json = TextReference }, ",\"presentation\":", H{ .json = protocol.ToolPresentationJson }, "}" };
    };
    pub const Rejected = struct {
        pub const openapi_name = "domainreportCurrentJsonRejected";
        pub const json_shape = .{ "{\"parent_operation\":\"", H.decimal, "\",\"call_ordinal\":\"", H.decimal, "\",\"code\":", H{ .string = 32 }, ",\"acceptance_position\":\"", H.decimal, "\",\"result\":", H{ .json = TextReference }, ",\"name\":", H{ .json = TextReference }, ",\"call_id\":", H{ .json = TextReference }, ",\"arguments\":", H{ .json = TextReference }, ",\"presentation\":", H{ .json = protocol.ToolPresentationJson }, "}" };
    };
    pub const Actions = struct {
        pub const openapi_name = "domainreportCurrentJsonActions";
        pub const json_shape = .{ "{\"count\":\"", H.decimal, "\",\"unresolved\":", ListOf(Unresolved), ",\"resolved\":", ListOf(Resolved), "}" };
    };
    pub const RejectedCalls = struct {
        pub const openapi_name = "domainreportCurrentJsonRejectedCalls";
        pub const json_shape = .{ "{\"count\":\"", H.decimal, "\",\"items\":", ListOf(Rejected), "}" };
    };
    pub const Actionable = struct {
        pub const openapi_name = "domainreportCurrentJsonActionable";
        pub const json_shape = .{ "{\"action\":\"", H.decimal, "\",\"permission_revision\":\"", H.decimal, "\"}" };
    };
};

fn maxTagBytes(comptime T: type) usize {
    var bytes: usize = 0;
    for (std.meta.tags(T)) |tag| bytes = @max(bytes, @tagName(tag).len);
    return bytes;
}
