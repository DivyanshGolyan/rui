//! What the Host answers when the row a stored reference names is gone.
//!
//! The Store carries no FOREIGN KEY in its v1 form, so a database team may delete any row directly and the database
//! will not object. The Host's rule is that a gone target has a typed outcome and is never `CorruptStore`.
//! This file owns the table of those outcomes, one per reference of the schema value, so the generated test that
//! deletes each target in turn is driven by the same list `rui store check` reads. A reference not yet decided is
//! `.undecided`; the test names each one, and deciding one is a one-line change (design: #2371).
const std = @import("std");
const schema = @import("schema.zig");

pub const Outcome = enum {
    /// The Session is gone: reads and commands answer `SessionNotFound`; a Turn running on it ends with a typed error.
    session_not_found,
    /// A link from one Session to another (a forward, a stop owed) whose other end is gone: the link is treated as
    /// absent, and a stop owed to a gone child counts as settled.
    link_absent,
    /// Shared content whose row is gone: the read carries a typed "content unavailable" part, and a Turn that needed it
    /// fails with a typed error.
    content_unavailable,
    /// Not decided yet; the Host may still read this as `CorruptStore`.
    undecided,
};

/// The outcome for a reference of `table`, named by the key's own columns and parent.
pub fn outcome(comptime table: []const u8, comptime key: schema.ForeignKey) Outcome {
    if (std.mem.eql(u8, key.references, "content")) return .content_unavailable;
    if (std.mem.eql(u8, key.references, "session")) {
        const links = std.mem.eql(u8, table, "session_forward") or std.mem.eql(u8, table, "session_stop_owed");
        return if (links) .link_absent else .session_not_found;
    }
    return .undecided;
}

/// The references of the schema value still `.undecided`, as `table(columns)->parent`.
pub fn undecided() []const []const u8 {
    return comptime blk: {
        var names: []const []const u8 = &.{};
        for (schema.tables) |table| for (table.foreign_keys) |key| {
            if (outcome(table.name, key) != .undecided) continue;
            var columns: []const u8 = "";
            for (key.columns, 0..) |column, position| columns = columns ++ (if (position == 0) "" else ",") ++ column;
            names = names ++ .{table.name ++ "(" ++ columns ++ ")->" ++ key.references};
        };
        break :blk names;
    };
}

/// Every reference of the schema value with the outcome it must have, written out by hand and not derived from
/// `outcome`, so a branch of `outcome` that changes fails here. A new reference, or one decided, is a line to change.
const expected = [_]struct { []const u8, Outcome }{
    .{ "content_chunk(content_id)->content", .content_unavailable },
    .{ "content_part(content_id)->content", .content_unavailable },
    .{ "content_part(part_content_id)->content", .content_unavailable },
    .{ "tool_record(description_content_id)->content", .content_unavailable },
    .{ "tool_record(input_schema_content_id)->content", .content_unavailable },
    .{ "tool_set_member(tool_set_id)->tool_set", .undecided },
    .{ "tool_set_member(tool_record_id)->tool_record", .undecided },
    .{ "host_tool_set(tool_set_id)->tool_set", .undecided },
    .{ "session(instructions_content_id)->content", .content_unavailable },
    .{ "session(tool_set_id)->tool_set", .undecided },
    .{ "session(loaded_tool_set_id)->tool_set", .undecided },
    .{ "session(output_schema_content_id)->content", .content_unavailable },
    .{ "session(parent_ref)->session", .session_not_found },
    .{ "session(creator_ref)->session", .session_not_found },
    .{ "session(archive_seq)->core_command", .undecided },
    .{ "session(app_tool_set_id)->tool_set", .undecided },
    .{ "session(app_lane)->session", .session_not_found },
    .{ "core_command(primary_content_id)->content", .content_unavailable },
    .{ "core_command(secondary_content_id)->content", .content_unavailable },
    .{ "session_revision(session_ref)->session", .session_not_found },
    .{ "session_revision(command_key)->core_command", .undecided },
    .{ "session_revision(instructions_content_id)->content", .content_unavailable },
    .{ "session_revision(tool_set_id)->tool_set", .undecided },
    .{ "session_revision(loaded_tool_set_id)->tool_set", .undecided },
    .{ "session_revision(app_tool_set_id)->tool_set", .undecided },
    .{ "session_revision(session_ref,effort_source_revision)->session_revision", .undecided },
    .{ "session_revision(output_schema_content_id)->content", .content_unavailable },
    .{ "session_change(session_ref)->session", .session_not_found },
    .{ "session_change(session_ref,revision)->session_revision", .undecided },
    .{ "session_change(refused_operation_id,session_ref,revision)->model_operation", .undecided },
    .{ "message_admission(session_ref)->session", .session_not_found },
    .{ "message_admission(command_key)->core_command", .undecided },
    .{ "message_admission(content_id)->content", .content_unavailable },
    .{ "message_admission(turn_id)->turn", .undecided },
    .{ "message_admission(sender_session_ref)->session", .session_not_found },
    .{ "message_admission(source_action_id)->action_operation", .undecided },
    .{ "action_value(action_id)->action_operation", .undecided },
    .{ "action_value(content_id)->content", .content_unavailable },
    .{ "action_value(admission_id)->message_admission", .undecided },
    .{ "turn(session_ref)->session", .session_not_found },
    .{ "turn(first_admission_id)->message_admission", .undecided },
    .{ "turn(outcome_content_id)->content", .content_unavailable },
    .{ "session_stop(command_key)->core_command", .undecided },
    .{ "session_stop(session_ref)->session", .session_not_found },
    .{ "session_stop(selected_turn_id)->turn", .undecided },
    .{ "session_archive_command(command_key)->core_command", .undecided },
    .{ "session_pin(session_ref)->session", .session_not_found },
    .{ "session_pin(command_key)->core_command", .undecided },
    .{ "session_pin_command(command_key)->core_command", .undecided },
    .{ "session_stop_owed(child_ref)->session", .link_absent },
    .{ "session_stop_owed(cause_ref)->session", .link_absent },
    .{ "session_forward(target_ref)->session", .link_absent },
    .{ "session_forward(child_ref)->session", .link_absent },
    .{ "model_interruption_command(command_key)->core_command", .undecided },
    .{ "model_operation(tool_set_id)->tool_set", .undecided },
    .{ "model_operation(turn_id)->turn", .undecided },
    .{ "model_operation(resolution_content_id)->content", .content_unavailable },
    .{ "model_operation(interrupted_by_command_key)->core_command", .undecided },
    .{ "model_operation(session_ref,settings_revision)->session_revision", .undecided },
    .{ "message_skill(admission_id)->message_admission", .undecided },
    .{ "message_skill(content_id)->content", .content_unavailable },
    .{ "session_skill_catalog(session_ref)->session", .session_not_found },
    .{ "session_skill_catalog(catalog_content_id)->content", .content_unavailable },
    .{ "conversation_entry(turn_id)->turn", .undecided },
    .{ "conversation_entry(source_admission_id)->message_admission", .undecided },
    .{ "conversation_entry(source_admission_id,source_kind)->message_admission", .undecided },
    .{ "conversation_entry(source_operation_id)->model_operation", .undecided },
    .{ "conversation_entry(content_id)->content", .content_unavailable },
    .{ "conversation_entry(session_ref,source_revision)->session_revision", .undecided },
    .{ "conversation_entry(session_ref,source_catalog_position)->session_skill_catalog", .undecided },
    .{ "conversation_entry(source_skill_admission_id,source_skill_position)->message_skill", .undecided },
    .{ "conversation_entry(source_operation_id,source_item_ordinal)->model_output_item", .undecided },
    .{ "model_output_item(operation_id)->model_operation", .undecided },
    .{ "model_output_item(message_content_id)->content", .content_unavailable },
    .{ "model_output_item(extras_content_id)->content", .content_unavailable },
    .{ "model_output_item(hosted_pattern_content_id)->content", .content_unavailable },
    .{ "hosted_target(operation_id,item_ordinal)->model_output_item", .undecided },
    .{ "hosted_target(content_id)->content", .content_unavailable },
    .{ "model_output_part(text_content_id)->content", .content_unavailable },
    .{ "model_output_part(extras_content_id)->content", .content_unavailable },
    .{ "model_tool_call(operation_id)->model_operation", .undecided },
    .{ "model_tool_call(operation_id,session_ref)->model_operation", .undecided },
    .{ "model_tool_call(name_content_id)->content", .content_unavailable },
    .{ "model_tool_call(call_id_content_id)->content", .content_unavailable },
    .{ "model_tool_call(arguments_content_id)->content", .content_unavailable },
    .{ "model_tool_call(rejection_content_id)->content", .content_unavailable },
    .{ "action_operation(parent_operation_id)->model_operation", .undecided },
    .{ "action_operation(session_ref)->session", .session_not_found },
    .{ "action_operation(resolution_content_id)->content", .content_unavailable },
    .{ "action_operation(background_content_id)->content", .content_unavailable },
    .{ "action_operation(parent_operation_id,session_ref)->model_operation", .undecided },
    .{ "action_operation(parent_operation_id,call_ordinal,tool_kind)->model_tool_call", .undecided },
    .{ "action_operation(session_ref,permission_revision)->session_revision", .undecided },
    .{ "permission_decision_command(command_key)->core_command", .undecided },
    .{ "action_stop(source_action_id)->action_operation", .undecided },
    .{ "action_stop(source_command_key)->core_command", .undecided },
    .{ "action_stop(target_action_id)->action_operation", .undecided },
    .{ "action_stop_command(command_key)->core_command", .undecided },
    .{ "action_control_command(command_key)->core_command", .undecided },
    .{ "action_control_command(selected_action_id)->action_operation", .undecided },
};

test "SH-188 every reference of the schema has the independently written outcome for a gone target" {
    var seen: usize = 0;
    inline for (schema.tables) |table| inline for (table.foreign_keys) |key| {
        comptime var columns: []const u8 = "";
        inline for (key.columns, 0..) |column, position| columns = columns ++ (if (position == 0) "" else ",") ++ column;
        const name = table.name ++ "(" ++ columns ++ ")->" ++ key.references;
        const want = for (expected) |entry| {
            if (std.mem.eql(u8, entry[0], name)) break entry[1];
        } else return error.ReferenceNotInExpectedTable;
        try std.testing.expectEqual(want, comptime outcome(table.name, key));
        seen += 1;
    };
    try std.testing.expectEqual(expected.len, seen);
    var undecided_expected: usize = 0;
    for (expected) |entry| {
        if (entry[1] != .undecided) continue;
        undecided_expected += 1;
        var listed = false;
        for (undecided()) |name| listed = listed or std.mem.eql(u8, name, entry[0]);
        try std.testing.expect(listed);
    }
    try std.testing.expectEqual(undecided_expected, undecided().len);
}
