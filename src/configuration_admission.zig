//! Configuration admission: why a configure command is refused. The Store
//! saves the code and the Host renders its tag name.

pub const Rejection = enum {
    invalid_session_reference,
    unknown_session,
    unsupported_permission_mode,
    unsupported_provider,
    invalid_model,
    model_capability_unavailable,
    invalid_output_schema,
    invalid_compaction_trigger,
    compact_at_too_large,
    invalid_output_reservation,
    unsupported_reasoning_effort,
    unknown_tool,
    mcp_server_unavailable,
    provider_tool_missing,
    loaded_tools_not_in_tools,
    loaded_tools_unreachable,
    invalid_label,
    incomplete_initial_configuration,
    unknown_preset,
    preset_on_update,
    invalid_workspace,
    workspace_is_immutable,
    provider_is_immutable,
    /// Historical saved rejection only; fresh model revisions are allowed.
    model_is_immutable,
    revision_exhausted,
    skills_unavailable,
};
