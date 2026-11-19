const Bounded = @import("bounded.zig").Bounded;

pub const Configuration = struct {
    provider: @import("provider_name.zig").Provider,
    model: Bounded(@import("model_capability.zig").max_model_bytes),
    reasoning_effort: ?@import("model_capability.zig").ReasoningEffort,
    workspace: Bounded(@import("workspace_path.zig").max_bytes),
    tools: Bounded(@import("tool_name.zig").max_names_bytes),
    loaded_tools: Bounded(@import("tool_name.zig").max_names_bytes),
    permission_mode: @import("cli_value.zig").PermissionMode,
    compaction_trigger: ?u64,
};
