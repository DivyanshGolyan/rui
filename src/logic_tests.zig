const std = @import("std");
const core_boundary = @import("core_boundary.zig");

/// Functional cores: decisions over values that their shells interpret.
/// `core_boundary.zig` defines what a core may name; the test below checks
/// each one listed here and runs its tests, and selector tests require each
/// to select test-logic. Add entries in alphabetical order by path, ignoring case.
const cores = .{
    .{ "action_control.zig", @import("action_control.zig") },
    .{ "action_read.zig", @import("action_read.zig") },
    .{ "action_receipt.zig", @import("action_receipt.zig") },
    .{ "action_text.zig", @import("action_text.zig") },
    .{ "action_value_limits.zig", @import("action_value_limits.zig") },
    .{ "ActionConsent.zig", @import("ActionConsent.zig") },
    .{ "activity_facts.zig", @import("activity_facts.zig") },
    .{ "activity_read.zig", @import("activity_read.zig") },
    .{ "activity_reply.zig", @import("activity_reply.zig") },
    .{ "answer_link_click.zig", @import("answer_link_click.zig") },
    .{ "app_input.zig", @import("app_input.zig") },
    .{ "attempt.zig", @import("attempt.zig") },
    .{ "attention.zig", @import("attention.zig") },
    .{ "bash_action_text.zig", @import("bash_action_text.zig") },
    .{ "BashLifecycle.zig", @import("BashLifecycle.zig") },
    .{ "bounded.zig", @import("bounded.zig") },
    .{ "built_in_tool.zig", @import("built_in_tool.zig") },
    .{ "byte_size.zig", @import("byte_size.zig") },
    .{ "call_classification.zig", @import("call_classification.zig") },
    .{ "caller_error.zig", @import("caller_error.zig") },
    .{ "caller_exit.zig", @import("caller_exit.zig") },
    .{ "change_ring.zig", @import("change_ring.zig") },
    .{ "chat_info_focus.zig", @import("chat_info_focus.zig") },
    .{ "chat_info_save.zig", @import("chat_info_save.zig") },
    .{ "chatgpt_plan_wire.zig", @import("chatgpt_plan_wire.zig") },
    .{ "citation_marker.zig", @import("citation_marker.zig") },
    .{ "cli_args.zig", @import("cli_args.zig") },
    .{ "cli_grammar.zig", @import("cli_grammar.zig") },
    .{ "cli_invocation.zig", @import("cli_invocation.zig") },
    .{ "cli_option_names.zig", @import("cli_option_names.zig") },
    .{ "cli_value.zig", @import("cli_value.zig") },
    .{ "codec_abi.zig", @import("codec_abi.zig") },
    .{ "codecs/json.zig", @import("codecs/json.zig") },
    .{ "codecs/messages.zig", @import("codecs/messages.zig") },
    .{ "codecs/responses.zig", @import("codecs/responses.zig") },
    .{ "codex_credential_policy.zig", @import("codex_credential_policy.zig") },
    .{ "codex_token_wire.zig", @import("codex_token_wire.zig") },
    .{ "command_input.zig", @import("command_input.zig") },
    .{ "command_reply.zig", @import("command_reply.zig") },
    .{ "command_spec.zig", @import("command_spec.zig") },
    .{ "command_value.zig", @import("command_value.zig") },
    .{ "configuration_admission.zig", @import("configuration_admission.zig") },
    .{ "configuration_defaults.zig", @import("configuration_defaults.zig") },
    .{ "configure_input.zig", @import("configure_input.zig") },
    .{ "configure_outcome.zig", @import("configure_outcome.zig") },
    .{ "connection.zig", @import("connection.zig") },
    .{ "connection_names.zig", @import("connection_names.zig") },
    .{ "content_string.zig", @import("content_string.zig") },
    .{ "content_value.zig", @import("content_value.zig") },
    .{ "conversation_read.zig", @import("conversation_read.zig") },
    .{ "copy_gesture.zig", @import("copy_gesture.zig") },
    .{ "creation_receipt.zig", @import("creation_receipt.zig") },
    .{ "creation_receipt_wire.zig", @import("creation_receipt_wire.zig") },
    .{ "deadline.zig", @import("deadline.zig") },
    .{ "defaults_report.zig", @import("defaults_report.zig") },
    .{ "descriptor_capacity.zig", @import("descriptor_capacity.zig") },
    .{ "display_text.zig", @import("display_text.zig") },
    .{ "download_policy.zig", @import("download_policy.zig") },
    .{ "draft_layout.zig", @import("draft_layout.zig") },
    .{ "endpoint_value.zig", @import("endpoint_value.zig") },
    .{ "entry_text.zig", @import("entry_text.zig") },
    .{ "environment.zig", @import("environment.zig") },
    .{ "error_set.zig", @import("error_set.zig") },
    .{ "excerpt.zig", @import("excerpt.zig") },
    .{ "failure_class.zig", @import("failure_class.zig") },
    .{ "feed_reads.zig", @import("feed_reads.zig") },
    .{ "find_tools_words.zig", @import("find_tools_words.zig") },
    .{ "first_line.zig", @import("first_line.zig") },
    .{ "github_observation.zig", @import("github_observation.zig") },
    .{ "github_pr_watch.zig", @import("github_pr_watch.zig") },
    .{ "github_pr_watch_descriptor.zig", @import("github_pr_watch_descriptor.zig") },
    .{ "github_watch_origin.zig", @import("github_watch_origin.zig") },
    .{ "hex_value.zig", @import("hex_value.zig") },
    .{ "home_path.zig", @import("home_path.zig") },
    .{ "host_activation.zig", @import("host_activation.zig") },
    .{ "host_drain.zig", @import("host_drain.zig") },
    .{ "host_reply.zig", @import("host_reply.zig") },
    .{ "host_restart.zig", @import("host_restart.zig") },
    .{ "host_settings.zig", @import("host_settings.zig") },
    .{ "host_settings_handoff.zig", @import("host_settings_handoff.zig") },
    .{ "hosted_action.zig", @import("hosted_action.zig") },
    .{ "HostStartupWait.zig", @import("HostStartupWait.zig") },
    .{ "http1/Parser.zig", @import("http1/Parser.zig") },
    .{ "http1/request.zig", @import("http1/request.zig") },
    .{ "idempotency_key.zig", @import("idempotency_key.zig") },
    .{ "input_media.zig", @import("input_media.zig") },
    .{ "input_parts.zig", @import("input_parts.zig") },
    .{ "json_ascii.zig", @import("json_ascii.zig") },
    .{ "json_limits.zig", @import("json_limits.zig") },
    .{ "json_scalar.zig", @import("json_scalar.zig") },
    .{ "keymap.zig", @import("keymap.zig") },
    .{ "line.zig", @import("line.zig") },
    .{ "marks.zig", @import("marks.zig") },
    .{ "mcp/action_text.zig", @import("mcp/action_text.zig") },
    .{ "mcp/arguments.zig", @import("mcp/arguments.zig") },
    .{ "mcp/document.zig", @import("mcp/document.zig") },
    .{ "mcp/EventStream.zig", @import("mcp/EventStream.zig") },
    .{ "mcp/headers.zig", @import("mcp/headers.zig") },
    .{ "mcp/listen.zig", @import("mcp/listen.zig") },
    .{ "mcp/post.zig", @import("mcp/post.zig") },
    .{ "mcp/relist.zig", @import("mcp/relist.zig") },
    .{ "mcp/reply.zig", @import("mcp/reply.zig") },
    .{ "mcp/result_parts.zig", @import("mcp/result_parts.zig") },
    .{ "mcp/result_parts_legacy_test.zig", @import("mcp/result_parts_legacy_test.zig") },
    .{ "mcp/result_text.zig", @import("mcp/result_text.zig") },
    .{ "mcp/result_text_golden_test.zig", @import("mcp/result_text_golden_test.zig") },
    .{ "mcp/result_text_legacy_test.zig", @import("mcp/result_text_legacy_test.zig") },
    .{ "mcp/shape.zig", @import("mcp/shape.zig") },
    .{ "memory_text.zig", @import("memory_text.zig") },
    .{ "message_admission.zig", @import("message_admission.zig") },
    .{ "message_agent_arguments.zig", @import("message_agent_arguments.zig") },
    .{ "message_observation.zig", @import("message_observation.zig") },
    .{ "model_capability.zig", @import("model_capability.zig") },
    .{ "model_catalog.zig", @import("model_catalog.zig") },
    .{ "model_catalog_snapshot.zig", @import("model_catalog_snapshot.zig") },
    .{ "model_evidence.zig", @import("model_evidence.zig") },
    .{ "model_list.zig", @import("model_list.zig") },
    .{ "model_picker.zig", @import("model_picker.zig") },
    .{ "model_picker_view.zig", @import("model_picker_view.zig") },
    .{ "models_dev.zig", @import("models_dev.zig") },
    .{ "mutation_answer.zig", @import("mutation_answer.zig") },
    .{ "mysql_url_value.zig", @import("mysql_url_value.zig") },
    .{ "outcome_code.zig", @import("outcome_code.zig") },
    .{ "output_item.zig", @import("output_item.zig") },
    .{ "overview_style.zig", @import("overview_style.zig") },
    // Includes the on-demand Lines projection and its fixture domain.
    .{ "overview_view.zig", @import("overview_view.zig") },
    .{ "part_text.zig", @import("part_text.zig") },
    .{ "path_list.zig", @import("path_list.zig") },
    .{ "preference_document.zig", @import("preference_document.zig") },
    .{ "preset_value.zig", @import("preset_value.zig") },
    .{ "process_memory.zig", @import("process_memory.zig") },
    .{ "product_defaults.zig", @import("product_defaults.zig") },
    .{ "protocol.zig", @import("protocol.zig") },
    .{ "provider_name.zig", @import("provider_name.zig") },
    .{ "provider_route.zig", @import("provider_route.zig") },
    .{ "provider_selection.zig", @import("provider_selection.zig") },
    .{ "queue_horizon.zig", @import("queue_horizon.zig") },
    .{ "queue_lifecycle.zig", @import("queue_lifecycle.zig") },
    .{ "queued_line.zig", @import("queued_line.zig") },
    .{ "read_image_arguments.zig", @import("read_image_arguments.zig") },
    .{ "release_schedule.zig", @import("release_schedule.zig") },
    .{ "replay_binding.zig", @import("replay_binding.zig") },
    .{ "replay_recipe.zig", @import("replay_recipe.zig") },
    .{ "request_wait.zig", @import("request_wait.zig") },
    .{ "required_settings.zig", @import("required_settings.zig") },
    .{ "result_fault.zig", @import("result_fault.zig") },
    .{ "result_layout.zig", @import("result_layout.zig") },
    .{ "retention_capacity.zig", @import("retention_capacity.zig") },
    .{ "retry_policy.zig", @import("retry_policy.zig") },
    .{ "saved_label.zig", @import("saved_label.zig") },
    .{ "schema_json.zig", @import("schema_json.zig") },
    .{ "secret_value.zig", @import("secret_value.zig") },
    .{ "serve_grammar.zig", @import("serve_grammar.zig") },
    .{ "session_archive.zig", @import("session_archive.zig") },
    .{ "session_chrome.zig", @import("session_chrome.zig") },
    .{ "session_class.zig", @import("session_class.zig") },
    .{ "session_consent.zig", @import("session_consent.zig") },
    .{ "session_departure.zig", @import("session_departure.zig") },
    .{ "session_id.zig", @import("session_id.zig") },
    .{ "session_keys.zig", @import("session_keys.zig") },
    .{ "session_line.zig", @import("session_line.zig") },
    .{ "session_list.zig", @import("session_list.zig") },
    .{ "session_notice.zig", @import("session_notice.zig") },
    .{ "session_pin.zig", @import("session_pin.zig") },
    .{ "session_reading.zig", @import("session_reading.zig") },
    .{ "session_settings.zig", @import("session_settings.zig") },
    .{ "session_upgrade.zig", @import("session_upgrade.zig") },
    .{ "session_work.zig", @import("session_work.zig") },
    .{ "sign_in.zig", @import("sign_in.zig") },
    .{ "skill_completion.zig", @import("skill_completion.zig") },
    .{ "skill_reference.zig", @import("skill_reference.zig") },
    .{ "skill_suggestions.zig", @import("skill_suggestions.zig") },
    .{ "slash_commands.zig", @import("slash_commands.zig") },
    .{ "slash_menu.zig", @import("slash_menu.zig") },
    .{ "source_kind.zig", @import("source_kind.zig") },
    .{ "start_report.zig", @import("start_report.zig") },
    .{ "status_page.zig", @import("status_page.zig") },
    .{ "store/command_replay.zig", @import("store/command_replay.zig") },
    .{ "store/engine/mysql_commit.zig", @import("store/engine/mysql_commit.zig") },
    .{ "store/engine/mysql_refusal.zig", @import("store/engine/mysql_refusal.zig") },
    .{ "store/page_slots.zig", @import("store/page_slots.zig") },
    .{ "store/pass_plan.zig", @import("store/pass_plan.zig") },
    .{ "store/round_order.zig", @import("store/round_order.zig") },
    .{ "store/wire/mysql.zig", @import("store/wire/mysql.zig") },
    .{ "store/write_batch.zig", @import("store/write_batch.zig") },
    .{ "store_id.zig", @import("store_id.zig") },
    .{ "store_path.zig", @import("store_path.zig") },
    .{ "store_target.zig", @import("store_target.zig") },
    .{ "submission_state.zig", @import("submission_state.zig") },
    .{ "TerminalText.zig", @import("TerminalText.zig") },
    .{ "theme.zig", @import("theme.zig") },
    .{ "tool_digests_generated.zig", @import("tool_digests_generated.zig") },
    .{ "tool_fold.zig", @import("tool_fold.zig") },
    .{ "tool_line.zig", @import("tool_line.zig") },
    .{ "tool_name.zig", @import("tool_name.zig") },
    .{ "tool_presentation.zig", @import("tool_presentation.zig") },
    .{ "tool_proposal.zig", @import("tool_proposal.zig") },
    .{ "tool_record.zig", @import("tool_record.zig") },
    .{ "transport_policy.zig", @import("transport_policy.zig") },
    .{ "turn_ending.zig", @import("turn_ending.zig") },
    .{ "turn_policy.zig", @import("turn_policy.zig") },
    .{ "unit_test_partition.zig", @import("unit_test_partition.zig") },
    .{ "upgrade_run.zig", @import("upgrade_run.zig") },
    .{ "upgrade_status.zig", @import("upgrade_status.zig") },
    .{ "url.zig", @import("url") },
    .{ "utf8_validation.zig", @import("utf8_validation.zig") },
    .{ "ViewportPosition.zig", @import("ViewportPosition.zig") },
    .{ "widgets/Feed.zig", @import("widgets/Feed.zig") },
    .{ "wire_field.zig", @import("wire_field.zig") },
    .{ "wire_version.zig", @import("wire_version.zig") },
    .{ "word_search.zig", @import("word_search.zig") },
    .{ "work_line.zig", @import("work_line.zig") },
    .{ "workspace_path.zig", @import("workspace_path.zig") },
};

test {
    _ = @import("credential_location.zig");
    _ = @import("testing/host_settings.zig");
    _ = @import("AnswerRenderer.zig");
    _ = @import("core_boundary.zig");
    _ = @import("execution.zig");
    _ = @import("execution_turn.zig");
    _ = @import("history_memo.zig");
    _ = @import("named_scratch.zig");
    _ = @import("prefix_seal.zig");
    _ = @import("codec_abi.zig");
    _ = @import("codecs.zig");
    _ = @import("new_session_selection.zig");
    _ = @import("request_encoding.zig");
    _ = @import("ResponseTiming.zig");
    _ = @import("ConversationViewport.zig");
    _ = @import("transcript_selection.zig");
    _ = @import("session_follow.zig");
    _ = @import("session_drafts.zig");
    _ = @import("SessionInput.zig");
    _ = @import("TerminalEditor.zig");
    _ = @import("DraftEditor.zig");
    _ = @import("keypress.zig");
    _ = @import("tools.zig");
    _ = @import("core_tools.zig");
    inline for (cores) |core| _ = core[1];
}

test "positional I/O errors retain provenance across the whole domain" {
    const fault = @import("result_fault.zig");
    inline for (.{ std.Io.File.ReadPositionalError, std.Io.File.WritePositionalError }) |ErrorSet| {
        inline for (@typeInfo(ErrorSet).error_set.error_names.?) |name| {
            const err = @field(anyerror, name);
            try std.testing.expectEqual(fault.Fault.rejected, fault.classify(.{ .source = err }));
            try std.testing.expectEqual(fault.Fault.uncertain, fault.classify(.{ .capture = err }));
            try std.testing.expectEqual(fault.Fault.uncertain, fault.classify(.{ .store = err }));
        }
    }
}

test "functional cores stay within the core boundary" {
    var previous: ?[]const u8 = null;
    inline for (cores) |core| {
        if (previous) |path| {
            if (std.ascii.orderIgnoreCase(path, core[0]) == .gt) {
                std.debug.print("functional cores out of order: {s} before {s}; move {s} before {s}\n", .{ path, core[0], core[0], path });
                return error.CoreOrderViolation;
            }
        }
        previous = core[0];
        // The checked source is the imported one.
        const path = comptime blk: {
            var name = @typeName(core[1]).*;
            std.mem.replaceScalar(u8, &name, '.', '/');
            const slashed = name;
            break :blk &slashed ++ ".zig";
        };
        try std.testing.expectEqualStrings(core[0], path);
        const names = comptime importNames(core[0]);
        if (core_boundary.check(@embedFile(core[0]), &names)) |violation| {
            std.debug.print("{s}:{d}: `{s}` is outside the core boundary; see src/core_boundary.zig\n", .{ core[0], violation.line, violation.text });
            return error.CoreBoundaryViolation;
        }
    }
}

/// Every core as `importer` spells its import: relative within its own
/// directory, else up to `src/` and down.
fn importNames(comptime importer: []const u8) [cores.len][]const u8 {
    @setEvalBranchQuota(100_000);
    const directory = importer[0..if (std.mem.lastIndexOfScalar(u8, importer, '/')) |slash| slash + 1 else 0];
    var up: []const u8 = "";
    for (0..std.mem.count(u8, directory, "/")) |_| up = up ++ "../";
    var names: [cores.len][]const u8 = undefined;
    for (cores, &names) |core, *name| name.* = if (directory.len > 0 and std.mem.startsWith(u8, core[0], directory))
        core[0][directory.len..]
    else
        up ++ core[0];
    return names;
}

test "the HTTP/2 client's proxy logic stays within the core boundary" {
    // A core of the self-contained h2 module, as its policy is.
    if (core_boundary.check(@embedFile("h2/proxy.zig"), &.{})) |violation| {
        std.debug.print("h2/proxy.zig:{d}: `{s}` is outside the core boundary; see src/core_boundary.zig\n", .{ violation.line, violation.text });
        return error.CoreBoundaryViolation;
    }
}

test "the HTTP/2 client's policy stays within the core boundary" {
    // A core of the self-contained h2 module: test-h2 runs its tests, and it
    // may import no Rui core.
    if (core_boundary.check(@embedFile("h2/policy.zig"), &.{})) |violation| {
        std.debug.print("h2/policy.zig:{d}: `{s}` is outside the core boundary; see src/core_boundary.zig\n", .{ violation.line, violation.text });
        return error.CoreBoundaryViolation;
    }
}

test "the HTTP/2 client's liveness stays within the core boundary" {
    if (core_boundary.check(@embedFile("h2/liveness.zig"), &.{})) |violation| {
        std.debug.print("h2/liveness.zig:{d}: `{s}` is outside the core boundary; see src/core_boundary.zig\n", .{ violation.line, violation.text });
        return error.CoreBoundaryViolation;
    }
}

test "the HTTP/2 client's dial policy stays within the core boundary" {
    if (core_boundary.check(@embedFile("h2/dial_policy.zig"), &.{"policy.zig"})) |violation| {
        std.debug.print("h2/dial_policy.zig:{d}: `{s}` is outside the core boundary; see src/core_boundary.zig\n", .{ violation.line, violation.text });
        return error.CoreBoundaryViolation;
    }
}

const overview_view = @import("overview_view.zig");
const GroupedList = @import("GroupedList.zig");
const protocol = @import("protocol.zig");
const protocol_reply = @import("protocol_reply.zig");

test "the overview core reads session list pages as the client decodes them" {
    comptime {
        std.debug.assert(overview_view.max_label_bytes == protocol.max_label_bytes);
        std.debug.assert(overview_view.max_page_rows == protocol.session_list_page_size);
    }
    var page: protocol_reply.SessionListPage = .{ .count = 2, .delta = .changed, .since = .{ .instance = @splat(7), .generation = 42 }, .next = .{ .since = null, .changed = .{ .through = 41, .after_reference = "r4t9vw".* } } };
    page.rows[0] = .{ .read_version = page.since, .work = .{ .state = .{ .approval = .{ .since = 1_792_925_300 } }, .attention = .{ .kind = .approval, .turn = 0, .step = 0 }, .group = .needs_you }, .peers = .{ .from_person_at = 1_792_925_001 } };
    try page.rows[0].reference.set("k7m2qx");
    try page.rows[0].workspace.set("/home/d/code/rui");
    page.rows[0].label = .{};
    try page.rows[0].label.?.set("Review PR 412");
    page.rows[0].first_message = .{ .position = 1, .admission = 4, .admitted_at = 1_792_925_001, .sender = null, .content = .{ .text = .{ .length = 5, .digest = @splat(0xaa) } } };
    page.rows[1] = .{ .read_version = page.since, .work = .{ .state = .{ .stopped = .{ .since = 1_792_925_400, .cause = .stop } } } };
    try page.rows[1].reference.set("r4t9vw");
    try page.rows[1].workspace.set("/srv/work");
    page.rows[1].first_message = .{ .position = 1, .admission = 9, .admitted_at = 1_792_925_002, .sender = .{ .session = .{} }, .content = .{ .text = .{ .length = 3, .digest = @splat(0xbb) } } };
    try page.rows[1].first_message.?.sender.?.session.set("k7m2qx");

    var traversal = protocol_reply.SessionTraversal.init(.{ .instance = @splat(7), .generation = 40 });
    var buffer: [overview_view.max_page_rows]overview_view.Listed = undefined;
    const read = overview_view.Page.of(&traversal, &page, &buffer, true);
    try std.testing.expect(!read.restarts);
    try std.testing.expectEqual(@as(?overview_view.Answer, null), read.answer);
    try std.testing.expectEqualDeep(page.next.?, traversal.cursor);
    try std.testing.expectEqual(@as(usize, 2), read.rows.len);
    const started = read.rows[0];
    try std.testing.expectEqualStrings("k7m2qx", &started.reference);
    try std.testing.expectEqualStrings("/home/d/code/rui", started.workspace);
    try std.testing.expectEqualStrings("Review PR 412", started.label.?);
    try std.testing.expectEqual(page.rows[0].work.state, started.state);
    try std.testing.expectEqualDeep(overview_view.First{ .position = 1, .admission = 4, .sender = null, .content = .{ .text = .{ .length = 5, .digest = @splat(0xaa) } } }, started.first.?);
    try std.testing.expectEqual(@as(?u64, 1_792_925_001), started.from_person_at);
    const delegated = read.rows[1];
    try std.testing.expectEqual(@as(?[]const u8, null), delegated.label);
    try std.testing.expectEqualStrings("k7m2qx", &delegated.first.?.sender.?);
    try std.testing.expectEqual(@as(?u64, null), delegated.from_person_at);

    // A changed listing whose next page is full starts over as that full
    // listing: the core keeps only the full listing's rows and token.
    var state: overview_view.State = undefined;
    try state.init(std.testing.allocator, .{ .cwd = "/home/d/code/rui", .home = "/home/d" });
    defer state.deinit();
    _ = try overview_view.step(&state, .{ .host = .{ .instance = page.since.instance, .started_at = 1_792_925_000, .slots = 2, .slots_in_use = 0 } });
    _ = try overview_view.step(&state, .{ .tick = 1_792_925_500_000 });
    _ = try overview_view.step(&state, .{ .list = .{ .page = read } });
    var full: protocol_reply.SessionListPage = .{ .count = 1, .delta = .full, .since = .{ .instance = @splat(9), .generation = 3 }, .next = null };
    full.rows[0] = page.rows[1];
    full.rows[0].read_version = full.since;
    const restarted = overview_view.Page.of(&traversal, &full, &buffer, true);
    try std.testing.expect(restarted.restarts);
    try std.testing.expectEqual(overview_view.Answer{ .delta = .full, .since = full.since }, restarted.answer.?);
    _ = try overview_view.step(&state, .{ .list = .{ .page = restarted } });
    try std.testing.expectEqual(@as(usize, 0), state.rows.items.len);
    try std.testing.expect(state.token == null);
    _ = try overview_view.step(&state, .{ .host = .{ .instance = full.since.instance, .started_at = 1_792_925_501, .slots = 2, .slots_in_use = 0 } });
    _ = try overview_view.step(&state, .{ .tick = state.next_list_ms });
    _ = try overview_view.step(&state, .{ .list = .{ .page = restarted } });
    try std.testing.expectEqual(@as(usize, 1), state.rows.items.len);
    try std.testing.expect(state.find("r4t9vw".*) != null);
    try std.testing.expectEqual(full.since, state.token.?);
}

/// Counts the allocations made through it.
const CountingAllocator = struct {
    child: std.mem.Allocator,
    count: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.count += 1;
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.count += 1;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

/// 10,000 Sessions in every kind, across 20 Workspaces.
fn benchmarkRows(rows: []overview_view.Listed, now_s: u64, shift: u64) void {
    const alphabet = "0123456789abcdefghjkmnpqrstvwxyz";
    const workspaces = comptime blk: {
        var paths: [20][]const u8 = undefined;
        for (&paths, 0..) |*path, at| path.* = std.fmt.comptimePrint("/home/d/code/project-{d}", .{at});
        break :blk paths;
    };
    const kinds = std.enums.values(overview_view.Kind);
    for (rows, 0..) |*row, at| {
        var reference: overview_view.Reference = undefined;
        var rest = at;
        for (0..reference.len) |digit| {
            reference[reference.len - 1 - digit] = alphabet[rest % alphabet.len];
            rest /= alphabet.len;
        }
        const since = now_s - (at * 37 + shift) % 86_400;
        const state: overview_view.WorkState = switch (kinds[(at + shift) % kinds.len]) {
            .idle => .{ .idle = .{ .since = since } },
            .pending => .{ .pending = .{ .since = since } },
            .working => .{ .working = .{ .since = since } },
            .retrying => .{ .retrying = .{ .since = since, .due_at_ms = (now_s + 30) * 1000, .cause = .{}, .attempt = 1 } },
            .bash => .{ .bash = .{ .since = since, .call = 0, .description = null, .running = 1, .approvals = 0 } },
            .approval => .{ .approval = .{ .since = since } },
            .stopping => .{ .stopping = .{ .since = since } },
            .finished => .{ .finished = .{ .since = since } },
            .failed => .{ .failed = .{ .since = since, .code = .{}, .resets_at = null } },
            .stopped => .{ .stopped = .{ .since = since, .cause = .stop } },
        };
        row.* = .{
            .reference = reference,
            .workspace = workspaces[at % workspaces.len],
            .provider = @import("connection.zig").Name.parse("codex").?,
            .label = if (at % 3 == 0) null else "Find why the store tests fail on the second run",
            .state = state,
            .state_change_at = since,
            .subtree_state_change_at = since,
            .descendant_count = 0,
            .descendant_needs_you_count = 0,
            .first = .{ .position = 1, .admission = at + 1, .sender = null, .content = .{ .text = .{ .length = 5, .digest = @splat(0xaa) } } },
            .from_person_at = if (at % 10 == 0) since else null,
        };
    }
}

/// Feeds `rows` to `state` as one full listing, eight per page. Returns the
/// nanoseconds its last page took, the step that merges the listing.
fn listAll(state: *overview_view.State, rows: []const overview_view.Listed, generation: u64) !u64 {
    var at: usize = 0;
    while (true) {
        const end = @min(at + overview_view.max_page_rows, rows.len);
        const start = nanosecondsNow();
        const answer: ?overview_view.Answer = if (end == rows.len) .{ .delta = .full, .since = .{ .instance = @splat(1), .generation = generation } } else null;
        var stamped: [overview_view.max_page_rows]overview_view.Listed = undefined;
        for (rows[at..end], stamped[0 .. end - at]) |row, *copy| {
            copy.* = row;
            copy.read_version = .{ .instance = @splat(1), .generation = generation };
        }
        _ = try overview_view.step(state, .{ .list = .{ .page = .{ .rows = stamped[0 .. end - at], .answer = answer } } });
        if (end == rows.len) return nanosecondsNow() - start;
        at = end;
    }
}

fn nanosecondsNow() u64 {
    return @intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds);
}

test "overview benchmark: batched initial and refreshed listings at 1,000 and 10,000 rows" {
    for ([_]usize{ 1_000, 10_000 }) |total| {
        const runs = 5;
        const now_s = 1_792_937_000;
        const rows = try std.testing.allocator.alloc(overview_view.Listed, total);
        defer std.testing.allocator.free(rows);
        var merge_ns: [runs]u64 = undefined;
        var initial_ns: [runs]u64 = undefined;
        var listing_ns: [runs]u64 = undefined;
        var render_ns: [runs]u64 = undefined;
        var merge_allocations: usize = 0;
        var render_allocations: usize = 0;
        for (0..runs) |run| {
            var list: GroupedList = .{};
            var counting: CountingAllocator = .{ .child = std.heap.smp_allocator };
            var state: overview_view.State = undefined;
            try state.init(counting.allocator(), .{ .cwd = "/home/d/code/project-0", .home = "/home/d" });
            defer state.deinit();
            _ = try overview_view.step(&state, .{ .host = .{ .instance = @splat(1), .started_at = now_s, .slots = 2, .slots_in_use = 0 } });
            _ = try overview_view.step(&state, .{ .tick = now_s * 1000 });
            benchmarkRows(rows, now_s, 0);
            initial_ns[run] = try listAll(&state, rows, 1);
            // A full refresh: every row again, many changed.
            _ = try overview_view.step(&state, .{ .tick = (now_s + 1) * 1000 });
            benchmarkRows(rows, now_s, run + 1);
            counting.count = 0;
            const listing_start = nanosecondsNow();
            merge_ns[run] = try listAll(&state, rows, 2);
            listing_ns[run] = nanosecondsNow() - listing_start;
            merge_allocations = @max(merge_allocations, counting.count);
            try std.testing.expectEqual(@as(usize, total), state.rows.items.len);

            _ = try overview_view.step(&state, .{ .resized = .{ .width = 200, .height = 60 } });
            counting.count = 0;
            const render_start = nanosecondsNow();
            // What App's overview builds each frame: the header, the list's
            // two-line rows on screen through GroupedList, and one Footer.
            var frame: std.heap.ArenaAllocator = .init(counting.allocator());
            _ = try overview_view.headerSegments(frame.allocator(), &state, 200, .{});
            const Source = struct {
                fn row(userdata: *const anyopaque, index: usize, arena: std.mem.Allocator) std.mem.Allocator.Error!GroupedList.Row {
                    const shown: *const overview_view.State = @ptrCast(@alignCast(userdata));
                    const built = (try overview_view.Lines.at(arena, shown, index, 200, .{}, 0)).?;
                    return .{ .segments = built.segments, .heading = built.heading };
                }
            };
            list.rows = .{ .userdata = &state, .count = @intCast(overview_view.Lines.count(&state)), .rowFn = Source.row };
            list.selected = if (overview_view.Lines.named(&state)) |at| @intCast(at) else null;
            _ = try list.widget().draw(.{ .arena = frame.allocator(), .cell_arena = frame.allocator(), .min = .{}, .max = .{ .width = 200, .height = 53 }, .cell_size = .{} });
            const footer: @import("widgets/Footer.zig") = .{ .left = "", .right = overview_view.footerRight(&state), .notice = overview_view.footerNotice(&state) };
            _ = try footer.widget().draw(.{ .arena = frame.allocator(), .cell_arena = frame.allocator(), .min = .{}, .max = .{ .width = 200, .height = 1 }, .cell_size = .{} });
            render_ns[run] = nanosecondsNow() - render_start;
            render_allocations = @max(render_allocations, counting.count);
            frame.deinit();
        }
        std.mem.sortUnstable(u64, &initial_ns, {}, std.sort.asc(u64));
        std.debug.print("overview initial batched merge, {d} rows: {d}us median\n", .{ total, initial_ns[runs / 2] / 1000 });
        std.mem.sortUnstable(u64, &merge_ns, {}, std.sort.asc(u64));
        std.mem.sortUnstable(u64, &listing_ns, {}, std.sort.asc(u64));
        std.mem.sortUnstable(u64, &render_ns, {}, std.sort.asc(u64));
        std.debug.print("overview benchmark, {d} rows: merging step {d}us median ({d}-{d}); whole listing {d}us median ({d}-{d}), {d} allocations; frame rows 200x60 {d}us median ({d}-{d}), {d} allocations\n", .{
            total,
            merge_ns[runs / 2] / 1000,
            merge_ns[0] / 1000,
            merge_ns[runs - 1] / 1000,
            listing_ns[runs / 2] / 1000,
            listing_ns[0] / 1000,
            listing_ns[runs - 1] / 1000,
            merge_allocations,
            render_ns[runs / 2] / 1000,
            render_ns[0] / 1000,
            render_ns[runs - 1] / 1000,
            render_allocations,
        });
        try std.testing.expect(merge_allocations <= total);
        try std.testing.expect(render_allocations <= total);
    }
}

test "a since walk the Host answers in full ends on that page, and a full walk pages on" {
    var traversal = protocol_reply.SessionTraversal.init(.{ .instance = @splat(7), .generation = 40 });
    var page: protocol_reply.SessionListPage = .{ .count = 0, .delta = .full, .since = .{ .instance = @splat(9), .generation = 3 }, .next = .{ .after = 8, .ceiling = 20 } };
    var buffer: [overview_view.max_page_rows]overview_view.Listed = undefined;
    const ended = overview_view.Page.of(&traversal, &page, &buffer, true);
    try std.testing.expectEqual(overview_view.Answer{ .delta = .full, .since = page.since }, ended.answer.?);
    var full_walk = protocol_reply.SessionTraversal.init(null);
    const paged = overview_view.Page.of(&full_walk, &page, &buffer, false);
    try std.testing.expectEqual(@as(?overview_view.Answer, null), paged.answer);
}
