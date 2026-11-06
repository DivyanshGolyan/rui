//! Shapes for the Full report's hand-written, streaming rows in report.zig.
//! Shared content references and enum domains retain their protocol owners.
const protocol = @import("../../protocol.zig");
const H = protocol.Hole;
const Reference = protocol.ActivityItem.Content;

fn ListOf(comptime T: type) type {
    return struct {
        pub const openapi_list = T;
    };
}

pub const Full = struct {
    pub const json_shape = .{
        "{\"session_revisions\":",    ListOf(Revision),
        ",\"messages\":",             ListOf(Message),
        ",\"conversation\":",         ListOf(Conversation),
        ",\"turns\":",                ListOf(Turn),
        ",\"model_operations\":",     ListOf(Operation),
        ",\"tool_calls\":",           ListOf(Call),
        ",\"actions\":",              ListOf(Action),
        ",\"permission_decisions\":", ListOf(Decision),
        ",\"session_stops\":",        ListOf(Stop),
        ",\"model_interruptions\":",  ListOf(Interruption),
        ",\"tool_results\":",         ListOf(Result),
        "}",
    };

    const Text = struct {
        pub const openapi_content = true;
    };
    const Tools = struct {
        pub const openapi_tools = true;
    };
    pub const Inline = struct {
        pub const json_shape = .{ "{\"type\":\"text\",\"bytes\":\"", H.decimal, "\",\"sha256\":\"", H{ .hex = 32 }, "\",\"text\":", Text, "}" };
    };
    pub const OwnedReference = struct {
        pub const json_shape = .{ "{\"bytes\":\"", H.decimal, "\",\"sha256\":\"", H{ .hex = 32 }, "\",\"owner\":{\"revision\":\"", H.decimal, "\",\"field\":\"", H{ .tag = @import("configuration.zig").RevisionContentField }, "\"}}" };
    };
    pub const RevisionContent = struct {
        pub const openapi_shapes = .{ Inline.json_shape, OwnedReference.json_shape };
    };
    pub const Revision = struct {
        pub const json_shape = .{
            "{\"revision\":\"",         H.decimal,                                        "\",\"command_key\":",      H{ .string = protocol.max_key_bytes },
            ",\"workspace\":",          H{ .string = protocol.max_workspace_bytes },      ",\"provider\":\"",         H{ .tag = protocol.Provider },
            "\",\"model\":",            H{ .string = protocol.max_model_bytes },          ",\"compaction_trigger\":", H.optional_id,
            ",\"output_reservation\":", H.optional_id,                                    ",\"reasoning_effort\":",   H{ .optional_tag = protocol.ReasoningEffort },
            ",\"label\":",              H{ .optional_string = protocol.max_label_bytes }, ",\"tools\":",              Tools,
            ",\"loaded_tools\":",       Tools,                                            ",\"permission_mode\":\"",  H{ .tag = protocol.PermissionMode },
            "\",\"instructions\":",     H{ .json = RevisionContent },                     ",\"output_schema\":",      H{ .optional_json = RevisionContent },
            "}",
        };
    };
    pub const Outcome = struct {
        pub const json_shape = .{ "{\"code\":", H{ .string = protocol.max_code_bytes }, ",\"content\":", H{ .optional_json = Reference }, "}" };
    };
    pub const Resolution = struct {
        pub const json_shape = .{ "{\"code\":", H{ .string = protocol.max_code_bytes }, ",\"content\":", H{ .optional_json = Inline }, "}" };
    };
    pub const Exclusion = struct {
        pub const json_shape = .{ "{\"code\":\"session_stopped\",\"command_key\":", H{ .string = protocol.max_key_bytes }, "}" };
    };
    pub const Message = struct {
        pub const json_shape = .{ "{\"admission\":\"", H.decimal, "\",\"command_key\":", H{ .string = protocol.max_key_bytes }, ",\"content\":", H{ .json = Inline }, ",\"turn\":", H.optional_id, ",\"application\":\"", H{ .tag = enum { applied, pending, excluded } }, "\",\"exclusion\":", H{ .optional_json = Exclusion }, ",\"outcome\":", H{ .optional_json = Outcome }, "}" };
    };
    pub const Conversation = struct {
        pub const json_shape = .{ "{\"ordinal\":\"", H.decimal, "\",\"position\":\"", H.decimal, "\",\"kind\":\"", H{ .tag = enum { message, settings, assistant } }, "\",\"turn\":", H.optional_id, ",\"source_admission\":", H.optional_id, ",\"source_revision\":", H.optional_id, ",\"source_catalog_position\":", H.optional_id, ",\"source_operation\":", H.optional_id, ",\"content\":", H{ .json = Reference }, "}" };
    };
    pub const Turn = struct {
        pub const json_shape = .{ "{\"turn\":\"", H.decimal, "\",\"first_admission\":\"", H.decimal, "\",\"input_cutoff\":\"", H.decimal, "\",\"operation\":\"", H.decimal, "\",\"outcome\":", H{ .optional_json = Outcome }, "}" };
    };
    pub const Operation = struct {
        pub const json_shape = .{ "{\"operation\":\"", H.decimal, "\",\"turn\":\"", H.decimal, "\",\"resolution\":", H{ .optional_json = Resolution }, ",\"interrupted_by\":", H{ .optional_string = protocol.max_key_bytes }, ",\"settings_revision\":\"", H.decimal, "\",\"request_id\":", H{ .optional_string = 256 }, ",\"reasoning_effort\":", H{ .optional_tag = protocol.ReasoningEffort }, "}" };
    };
    pub const Call = struct {
        pub const json_shape = .{ "{\"operation\":\"", H.decimal, "\",\"call_ordinal\":\"", H.decimal, "\",\"item_ordinal\":\"", H.decimal, "\",\"rejection\":", H{ .optional_string = 32 }, ",\"acceptance_position\":", H.optional_id, ",\"name\":", H{ .json = Inline }, ",\"call_id\":", H{ .json = Inline }, ",\"arguments\":", H{ .json = Inline }, ",\"rejection_result\":", H{ .optional_json = Inline }, "}" };
    };
    pub const Action = struct {
        pub const json_shape = .{ "{\"action\":\"", H.decimal, "\",\"parent_operation\":\"", H.decimal, "\",\"call_ordinal\":\"", H.decimal, "\",\"permission_revision\":\"", H.decimal, "\",\"permission\":\"", H{ .tag = enum { denied, authorized, requested } }, "\",\"resolution\":", H{ .optional_string = @import("action.zig").max_action_resolution_code_bytes }, ",\"result\":", H{ .optional_json = Inline }, ",\"acceptance_position\":", H.optional_id, "}" };
    };
    pub const Decision = struct {
        pub const json_shape = .{ "{\"command_key\":", H{ .string = protocol.max_key_bytes }, ",\"action\":", H{ .string = 20 }, ",\"decision\":\"", H{ .tag = protocol.PermissionDecision }, "\",\"status\":\"", H{ .tag = enum { accepted, rejected } }, "\",\"code\":", H{ .string = 96 }, "}" };
    };
    pub const Stop = struct {
        pub const json_shape = .{ "{\"command_key\":", H{ .string = protocol.max_key_bytes }, ",\"status\":\"", H{ .tag = enum { accepted, rejected } }, "\",\"code\":", H{ .string = 96 }, ",\"selected_turn\":", H.optional_id, ",\"admission_cutoff\":", H.optional_id, "}" };
    };
    pub const Interruption = struct {
        pub const json_shape = .{ "{\"command_key\":", H{ .string = protocol.max_key_bytes }, ",\"status\":\"", H{ .tag = enum { accepted, rejected } }, "\",\"code\":", H{ .string = 96 }, ",\"turn\":", H{ .string = 20 }, ",\"operation\":", H{ .string = 20 }, "}" };
    };
    pub const Result = struct {
        pub const json_shape = .{ "{\"operation\":\"", H.decimal, "\",\"call_ordinal\":\"", H.decimal, "\",\"acceptance_position\":\"", H.decimal, "\",\"call_id\":", H{ .json = Inline }, ",\"code\":", H{ .string = 32 }, ",\"result\":", H{ .json = Inline }, "}" };
    };
};
